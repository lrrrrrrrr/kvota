#!/usr/bin/env python3
"""Kvota check: does Claude Code on this Mac run Kvota's status line bridge?

    python3 kvota-check.py            # local checks only
    python3 kvota-check.py --live     # also start `claude` once and watch the bridge run
    python3 kvota-check.py --live --message
                                      # ...and send one short message, so Claude Code
                                      # shares your plan limits (uses a tiny bit of usage)

Prints a report and saves it to ~/Downloads/kvota-check-report.txt. It never prints
tokens or other secrets: from settings files it shows only the keys Kvota cares about,
and environment variable names without their values. Standard library only.
"""
import json
import os
import pathlib
import re
import select
import shutil
import subprocess
import sys
import tempfile
import time

HOME = pathlib.Path(os.environ.get("KVOTA_CHECK_HOME") or pathlib.Path.home())
CLAUDE = pathlib.Path(os.environ.get("CLAUDE_CONFIG_DIR") or HOME / ".claude")
KVOTA = CLAUDE / "kvota"
MARKER = "kvota/statusline-bridge.sh"
REPORT = HOME / "Downloads" / "kvota-check-report.txt"
NOW = time.time()

lines = []


def out(text=""):
    print(text, flush=True)
    lines.append(text)


def ok(text):
    out("  OK    " + text)


def warn(text):
    out("  WARN  " + text)


def bad(text):
    out("  FAIL  " + text)


def info(text):
    out("        " + text)


def ago(ts):
    seconds = NOW - ts
    if seconds < 0:
        return "in the future"
    if seconds < 90:
        return "%d s ago" % seconds
    if seconds < 5400:
        return "%d min ago" % (seconds / 60)
    if seconds < 172800:
        return "%.1f h ago" % (seconds / 3600)
    return "%.1f days ago" % (seconds / 86400)


def read_json(path):
    try:
        return json.loads(pathlib.Path(path).read_text())
    except FileNotFoundError:
        return None
    except Exception as error:
        return {"__unreadable__": str(error)}


# ------------------------------------------------------------------ the claude command

def find_claude():
    out("\n1. The claude command")
    found = shutil.which("claude")
    candidates = [found] if found else []
    for extra in ("~/.local/bin/claude", "~/.claude/local/claude", "/opt/homebrew/bin/claude",
                  "/usr/local/bin/claude", "~/.npm-global/bin/claude"):
        path = os.path.expanduser(extra.replace("~", str(HOME), 1)) if extra.startswith("~") else extra
        if os.path.isfile(path) and os.access(path, os.X_OK) and path not in candidates:
            candidates.append(path)
    if not candidates:
        bad("no claude command on this Mac. The status line only runs in the claude command-line tool")
        info("(the Claude desktop app doesn't run status lines). Install: https://code.claude.com/docs/en/setup")
        return None
    claude = candidates[0]
    if found:
        ok("claude is on your PATH: " + found)
    else:
        warn("claude exists at %s but isn't on your PATH, so typing claude may not work" % claude)
    try:
        version = subprocess.run([claude, "--version"], capture_output=True, text=True, timeout=30).stdout.strip()
        info("version: " + (version or "unknown"))
    except Exception as error:
        warn("couldn't run claude --version: %s" % error)
    for other in candidates[1:]:
        info("another copy: " + other)
    return claude


# ------------------------------------------------------------------ settings

other_provider = [False]


def check_settings():
    out("\n2. Claude Code settings (%s)" % CLAUDE)
    if os.environ.get("CLAUDE_CONFIG_DIR"):
        info("CLAUDE_CONFIG_DIR is set, so Claude Code uses that folder")
    bridge_ok = False
    for name in ("settings.json", "settings.local.json"):
        path = CLAUDE / name
        data = read_json(path)
        if data is None:
            info("%s: not present" % name)
            continue
        if "__unreadable__" in data:
            bad("%s can't be read as JSON: %s" % (name, data["__unreadable__"]))
            continue
        status = data.get("statusLine")
        if status is not None:
            command = (status or {}).get("command", "") if isinstance(status, dict) else str(status)
            if MARKER in command:
                ok("%s: statusLine runs Kvota's bridge" % name)
                info("type: %s, command: %s" % (status.get("type"), command))
                bridge_ok = True
            else:
                warn("%s: statusLine runs something else: %s" % (name, command[:120]))
        else:
            info("%s: no statusLine" % name)
        if data.get("disableAllHooks"):
            bad("%s sets disableAllHooks: true, which turns custom status lines off" % name)
        env = data.get("env") or {}
        if isinstance(env, dict):
            interesting = sorted(k for k in env if k.startswith(("ANTHROPIC", "CLAUDE")))
            if interesting:
                info("%s sets environment variables (names only): %s" % (name, ", ".join(interesting)))
            if "ANTHROPIC_BASE_URL" in env or "ANTHROPIC_AUTH_TOKEN" in env or "ANTHROPIC_API_KEY" in env:
                other_provider[0] = True
                base = str(env.get("ANTHROPIC_BASE_URL", ""))
                host = re.sub(r"^https?://([^/]+).*$", r"\1", base) if base else ""
                bad("%s points Claude Code at %s instead of your Claude plan: Claude Code then has no"
                    % (name, host or "an API key"))
                info("Claude plan limits to share, in the claude command (and possibly the desktop app)")
    for managed in ("/Library/Application Support/ClaudeCode/managed-settings.json",):
        data = read_json(managed)
        if data:
            warn("managed settings exist: %s" % managed)
            for key in ("disableAllHooks", "allowManagedHooksOnly", "statusLine"):
                if key in data:
                    info("managed %s = %s" % (key, json.dumps(data[key])[:120]))
    for var in ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX"):
        if os.environ.get(var):
            warn("%s is set in this shell: Claude Code may not use your Claude plan" % var)
    if not bridge_ok:
        bad("Kvota's bridge isn't the status line. Click Connect status line in Kvota")
    return bridge_ok


# ------------------------------------------------------------------ bridge files

def check_bridge_files():
    out("\n3. Kvota's bridge folder (%s)" % KVOTA)
    script = KVOTA / "statusline-bridge.sh"
    if not script.exists():
        bad("statusline-bridge.sh is missing")
        return None
    if os.access(str(script), os.X_OK):
        ok("statusline-bridge.sh exists and is executable")
    else:
        bad("statusline-bridge.sh isn't executable")
    previous = KVOTA / "statusline-command"
    if previous.exists() and previous.read_text().strip():
        info("your previous status line command runs after the bridge")
    for name in ("last_run.json", "rate_limits.json"):
        path = KVOTA / name
        if path.exists():
            info("%s (%s): %s" % (name, ago(path.stat().st_mtime), path.read_text().strip()[:300]))
        else:
            info("%s: not written yet" % name)
    return script


def simulate(script):
    out("\n4. Bridge test with sample data (in a temporary folder)")
    with tempfile.TemporaryDirectory() as folder:
        copy = pathlib.Path(folder) / "statusline-bridge.sh"
        shutil.copy(str(script), str(copy))
        os.chmod(str(copy), 0o755)
        sample = {
            "model": {"display_name": "Test"}, "version": "0.0.0",
            "context_window": {"current_usage": {"input_tokens": 1}},
            "rate_limits": {"five_hour": {"used_percentage": 42, "resets_at": int(NOW) + 3600},
                            "seven_day": {"used_percentage": 7, "resets_at": int(NOW) + 86400}},
        }
        try:
            run = subprocess.run(["/bin/sh", "-c", "'%s'" % copy], input=json.dumps(sample),
                                 capture_output=True, text=True, timeout=10)
        except Exception as error:
            bad("the bridge didn't run: %s" % error)
            return
        written = sorted(p.name for p in pathlib.Path(folder).glob("*.json"))
        if run.returncode == 0 and "rate_limits.json" in written and "last_run.json" in written:
            ok("the bridge works: printed %r, wrote %s" % (run.stdout.strip(), ", ".join(written)))
        else:
            bad("the bridge failed (exit %s): %s %s" % (run.returncode, run.stderr.strip()[:200], written))


# ------------------------------------------------------------------ which apps write the logs

def check_logs():
    out("\n5. Where your Claude Code sessions on this Mac come from (last 14 days)")
    projects = CLAUDE / "projects"
    counts = {}
    limit_keys = {}
    newest = None
    for path in projects.glob("*/*.jsonl"):
        try:
            mtime = path.stat().st_mtime
        except OSError:
            continue
        if NOW - mtime > 14 * 86400:
            continue
        newest = max(newest or 0, mtime)
        try:
            with open(str(path), "rb") as handle:
                handle.seek(max(0, path.stat().st_size - 200000))
                tail = handle.read().decode("utf-8", "replace")
        except OSError:
            continue
        for value in re.findall(r'"entrypoint"\s*:\s*"([^"]+)"', tail):
            counts[value] = counts.get(value, 0) + 1
        for key in re.findall(r'"(rate_limits?|rateLimit\w*|five_hour|seven_day|utilization|resets_?[aA]t)"', tail):
            limit_keys[key] = limit_keys.get(key, 0) + 1
    if not counts:
        info("no recent session logs with an entrypoint field")
        return
    for value, count in sorted(counts.items(), key=lambda item: -item[1]):
        label = {"cli": "the claude command (runs status lines)"}.get(value, "not the claude command (no status lines)")
        info("%-22s %6d log lines  (%s)" % (value, count, label))
    if "cli" not in counts:
        warn("none of your recent Claude Code use is from the claude command, so the status line never ran")
    if newest:
        info("newest session log: " + ago(newest))
    if limit_keys:
        info("rate-limit fields found in the logs: %s" % ", ".join("%s x%d" % kv for kv in sorted(limit_keys.items())))
    else:
        info("the logs contain no rate-limit data (Claude Code doesn't write limits to its logs)")


# ------------------------------------------------------------------ live test

def live_test(claude, send_message, uses_other_provider):
    out("\n6. Live test: start claude once and watch the bridge")
    import pty  # macOS and Linux only

    last_run = KVOTA / "last_run.json"
    before = last_run.stat().st_mtime if last_run.exists() else 0
    folder = tempfile.mkdtemp(prefix="kvota-check-")
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(folder)
        os.environ.setdefault("TERM", "xterm-256color")
        os.execv(claude, [claude])
    buffer = b""

    def pump(seconds, until=None):
        nonlocal buffer
        end = time.time() + seconds
        while time.time() < end:
            ready, _, _ = select.select([fd], [], [], 0.25)
            if ready:
                try:
                    buffer += os.read(fd, 65536)
                except OSError:
                    return False
            if until and until():
                return True
        return False

    def screen():
        text = re.sub(rb"\x1b\[[0-9;?<>=]*[A-Za-z~]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)|\x1b[()][A-Z0-9]|\x1b[=>78]", b" ", buffer)
        return re.sub(r"\s+", " ", text.decode("utf-8", "replace"))

    def ran():
        return last_run.exists() and last_run.stat().st_mtime > before

    def send(data):
        try:
            os.write(fd, data)
        except OSError:
            pass  # claude has exited

    def screen_since(mark):
        text = re.sub(rb"\x1b\[[0-9;?<>=]*[A-Za-z~]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)|\x1b[()][A-Z0-9]|\x1b[=>78]", b" ", buffer[mark:])
        return re.sub(r"\s+", " ", text.decode("utf-8", "replace"))

    # Get past any dialogs Claude Code shows before the session starts: the folder trust
    # question (status lines don't run until the folder is trusted) and announcements.
    mark = 0
    deadline = time.time() + 45
    while not ran() and time.time() < deadline:
        pump(3, ran)
        fresh = screen_since(mark)
        if ran() or not fresh.strip():
            continue
        if re.search(r"I trust this folder|Do you trust", fresh, re.I):
            info("claude asked whether to trust the new empty test folder; choosing Yes")
            picks = re.findall("[\u276f>]\\s*(?:\\d\\.\\s*)?(Yes, I trust|No, exit)", fresh)
            if picks and picks[-1] == "No, exit":
                # The menu cursor is on "No, exit": move it to "Yes, I trust this folder".
                up = fresh.rfind("Yes, I trust") < fresh.rfind("No, exit")
                send(b"\x1b[A" if up else b"\x1b[B")
                pump(0.5)
            send(b"\r")
        elif re.search(r"Enter to (confirm|continue)|Press Enter", fresh, re.I):
            info("closing a Claude Code notice: " + fresh.strip()[:80])
            send(b"\x1b")
        else:
            continue
        mark = len(buffer)
    if ran():
        ok("Claude Code ran the bridge when the session started: " + last_run.read_text().strip())
    else:
        bad("Claude Code started but didn't run the bridge within 45 seconds")
        info("screen: " + screen()[-600:])
    if send_message and ran() and uses_other_provider:
        info("not sending a test message: your settings send Claude Code to another provider,")
        info("which has no Claude plan limits to share")
    if send_message and ran() and not uses_other_provider:
        info("sending one short message so Claude Code shares your plan limits")
        send(b"Reply with just the word OK.\r")
        limits = KVOTA / "rate_limits.json"
        start = limits.stat().st_mtime if limits.exists() else 0
        sent = time.time()

        def limits_arrived():
            return limits.exists() and limits.stat().st_mtime > start

        def replied():
            # The bridge runs again when the reply arrives, with or without limits.
            return limits_arrived() or (last_run.stat().st_mtime > sent + 0.5
                                        and '"replied":true' in last_run.read_text())

        pump(90, replied)
        pump(3, limits_arrived)
        got = limits_arrived()
        if got:
            ok("limits arrived: " + limits.read_text().strip()[:300])
        else:
            run = read_json(last_run) or {}
            bad("no limits after the reply (last run: %s)" % json.dumps(run))
            info("Claude Code only shares limits when signed in with a Claude Pro or Max plan")
            info("screen: " + screen()[-600:])
    send(b"\x03")
    pump(1)
    send(b"\x03")
    pump(2)
    try:
        os.kill(pid, 9)
    except OSError:
        pass
    shutil.rmtree(folder, ignore_errors=True)


def main():
    out("Kvota check - %s" % time.strftime("%Y-%m-%d %H:%M"))
    claude = find_claude()
    check_settings()
    script = check_bridge_files()
    if script:
        simulate(script)
    check_logs()
    try:
        if "--live" in sys.argv and claude:
            live_test(claude, "--message" in sys.argv, other_provider[0])
    except Exception as error:
        bad("the live test stopped: %r" % error)
    out("\nNo secrets were printed.")
    try:
        REPORT.parent.mkdir(parents=True, exist_ok=True)
        REPORT.write_text("\n".join(lines) + "\n")
        print("Saved to %s" % REPORT)
    except OSError as error:
        print("Couldn't save the report: %s" % error)


if __name__ == "__main__":
    main()
