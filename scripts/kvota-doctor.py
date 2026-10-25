#!/usr/bin/env python3
"""Kvota doctor: checks what Kvota can read on this Mac for Claude Code, Codex CLI and
Gemini CLI.

    python3 kvota-doctor.py

It only looks at local files, like Kvota itself: it never reads a login token and never
contacts any server. Uses only the Python standard library.
"""
import datetime as dt
import json
import os
import pathlib

HOME = pathlib.Path.home()
NOW = dt.datetime.now(dt.timezone.utc)


def ok(text):
    print(f"  ✅ {text}")


def warn(text):
    print(f"  ⚠️  {text}")


def bad(text):
    print(f"  ❌ {text}")


def info(text):
    print(f"     {text}")


def when(epoch):
    if epoch is None:
        return "unknown"
    if epoch > 95_000_000_000:  # milliseconds
        epoch /= 1000
    moment = dt.datetime.fromtimestamp(epoch, dt.timezone.utc)
    delta = moment - NOW
    hours = abs(delta.total_seconds()) / 3600
    span = f"{hours:.1f} h" if hours < 48 else f"{hours / 24:.1f} days"
    return f"{moment.astimezone():%Y-%m-%d %H:%M} ({'in ' + span if delta.total_seconds() > 0 else span + ' ago'})"


def read_json(path):
    try:
        return json.loads(pathlib.Path(path).read_text())
    except FileNotFoundError:
        return None
    except Exception as error:
        return {"__error__": str(error)}


def limits_line(windows):
    parts = []
    for name, window in windows:
        if not isinstance(window, dict):
            continue
        used = window.get("used_percent")
        if used is None:
            continue
        parts.append(f"{name} {100 - float(used):.0f}% left")
    return ", ".join(parts) if parts else "no limit windows in the answer"


# ---------------------------------------------------------------- Claude Code

def check_claude():
    print("\nClaude Code")
    folder = HOME / ".claude"
    if not folder.is_dir():
        bad("~/.claude not found: Claude Code hasn't run on this Mac as this user")
        return
    ok("~/.claude exists")
    projects = list((folder / "projects").glob("*/*.jsonl"))
    info(f"{len(projects)} session logs in ~/.claude/projects")

    for var in ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX"):
        if os.environ.get(var):
            warn(f"{var} is set in this shell: Claude Code may use it instead of a Claude subscription")
    base_url = os.environ.get("ANTHROPIC_BASE_URL", "")
    if base_url and "api.anthropic.com" not in base_url:
        warn(f"ANTHROPIC_BASE_URL points to {base_url}: Claude Code talks to another service, which has no Claude plan limits")
    if os.environ.get("CLAUDE_CONFIG_DIR"):
        info(f"CLAUDE_CONFIG_DIR = {os.environ['CLAUDE_CONFIG_DIR']}")

    settings = read_json(folder / "settings.json") or {}
    command = (settings.get("statusLine") or {}).get("command", "") if isinstance(settings, dict) else ""
    if "kvota" in command:
        ok("Kvota's status line bridge is connected")
        snapshot = folder / "kvota" / "rate_limits.json"
        if snapshot.exists():
            ok(f"bridge has saved limits ({when(snapshot.stat().st_mtime)})")
        else:
            warn("bridge hasn't received limits yet (needs a reply in the claude command-line tool, Pro/Max only)")
    else:
        info("status line bridge not connected")

    run = read_json(folder / "kvota" / "last_run.json")
    if isinstance(run, dict) and run.get("at"):
        info(f"status line last ran {when(run['at'])}; "
             f"limits included: {'yes' if run.get('rate_limits') else 'no'}")
    info("Without the status line, Kvota estimates the 5-hour session and week from these logs")


# ---------------------------------------------------------------- Codex

def check_codex():
    print("\nCodex CLI")
    folder = HOME / ".codex"
    if not folder.is_dir():
        bad("~/.codex not found")
        return
    ok("~/.codex exists")
    rollouts = list((folder / "sessions").rglob("rollout-*.jsonl*"))
    info(f"{len(rollouts)} session logs in ~/.codex/sessions")
    if not rollouts:
        warn("no session logs yet: limits appear after your first Codex reply")
        return
    newest = max(rollouts, key=lambda p: p.stat().st_mtime)
    info(f"newest session log: {when(newest.stat().st_mtime)}")
    if newest.suffix == ".zst":
        info("newest log is compressed; Kvota reads it, this script doesn't")
        return
    limits = None
    try:
        for line in newest.read_text(errors="replace").splitlines():
            if '"rate_limits"' not in line:
                continue
            try:
                payload = (json.loads(line).get("payload") or {})
            except json.JSONDecodeError:
                continue
            if isinstance(payload.get("rate_limits"), dict):
                limits = payload["rate_limits"]
    except OSError as error:
        bad(f"couldn't read the newest log: {error}")
        return
    if limits:
        ok("limits found in the newest log: "
           + limits_line([("5-hour", limits.get("primary")), ("weekly", limits.get("secondary"))]))
    else:
        warn("the newest log has no limits (API-key sign-ins have none)")


# ---------------------------------------------------------------- Gemini

def check_gemini():
    print("\nGemini CLI")
    folder = HOME / ".gemini"
    if not folder.is_dir():
        bad("~/.gemini not found")
        return
    ok("~/.gemini exists")
    chats = list((folder / "tmp").glob("*/chats/session-*"))
    info(f"{len(chats)} chat recordings in ~/.gemini/tmp")
    if chats:
        newest = max(chats, key=lambda p: p.stat().st_mtime)
        info(f"newest chat recording: {when(newest.stat().st_mtime)}")
    else:
        warn("no chat recordings yet: usage appears after your first Gemini reply")
    info("Gemini CLI doesn't store its quota on disk, so Kvota shows token usage only")


if __name__ == "__main__":
    print(f"Kvota doctor — {NOW.astimezone():%Y-%m-%d %H:%M}")
    for check in (check_claude, check_codex, check_gemini):
        try:
            check()
        except Exception as error:  # keep going so the other providers are still checked
            bad(f"check failed: {error}")
    print("\nNothing secret was printed. Share this output if you want help reading it.")
