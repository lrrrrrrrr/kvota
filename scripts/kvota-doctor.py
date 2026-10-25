#!/usr/bin/env python3
"""Kvota doctor: checks what Kvota can read on this Mac for Claude Code, Codex CLI and
Gemini CLI, and whether each provider's usage endpoint answers.

    python3 kvota-doctor.py            # local checks + one test request per provider
    python3 kvota-doctor.py --offline  # local checks only

It never prints tokens or keys: only whether they exist, when they expire, plan names
and HTTP status codes. Uses only the Python standard library and macOS's own tools.
"""
import base64
import datetime as dt
import json
import os
import pathlib
import shutil
import subprocess
import sys

HOME = pathlib.Path.home()
OFFLINE = "--offline" in sys.argv
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


def jwt_exp(token):
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        return json.loads(base64.urlsafe_b64decode(payload)).get("exp")
    except Exception:
        return None


def read_json(path):
    try:
        return json.loads(pathlib.Path(path).read_text())
    except FileNotFoundError:
        return None
    except Exception as error:
        return {"__error__": str(error)}


def curl(url, headers, method="GET", body=None):
    """Runs curl with headers passed on stdin, so tokens never appear in the process list."""
    if OFFLINE:
        return None, None
    header_text = "".join(f"{k}: {v}\n" for k, v in headers.items())
    args = ["/usr/bin/curl", "-sS", "-m", "15", "-X", method, "-H", "@-", "-w", "\n%{http_code}", url]
    if body is not None:
        args[1:1] = ["--data-binary", body]
    try:
        out = subprocess.run(args, input=header_text, capture_output=True, text=True, timeout=20)
    except Exception as error:
        return None, str(error)
    if out.returncode != 0:
        return None, out.stderr.strip() or f"curl exit {out.returncode}"
    text, _, code = out.stdout.rpartition("\n")
    try:
        return int(code), text
    except ValueError:
        return None, out.stdout[-200:]


def keychain_services(prefix):
    try:
        dump = subprocess.run(["/usr/bin/security", "dump-keychain"], capture_output=True, text=True, timeout=20).stdout
    except Exception:
        return []
    names = set()
    for line in dump.splitlines():
        line = line.strip()
        if line.startswith('"svce"') and prefix.lower() in line.lower():
            value = line.split("=", 1)[-1].strip().strip('"')
            names.add(value)
    return sorted(names)


def keychain_secret(service):
    try:
        out = subprocess.run(
            ["/usr/bin/security", "find-generic-password", "-s", service, "-w"],
            capture_output=True, text=True, timeout=60,
        )
    except Exception as error:
        return None, str(error)
    if out.returncode != 0:
        return None, out.stderr.strip()
    text = out.stdout.strip()
    if text and not text.startswith("{"):
        try:
            text = bytes.fromhex(text).decode()
        except ValueError:
            pass
    return text, None


def limits_line(windows):
    parts = []
    for name, window in windows:
        if not isinstance(window, dict):
            continue
        used = window.get("utilization", window.get("used_percent"))
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

    creds = None
    file_creds = read_json(folder / ".credentials.json")
    if file_creds:
        ok("~/.claude/.credentials.json exists")
        creds = file_creds
    services = keychain_services("Claude Code")
    if services:
        ok(f"Keychain items: {', '.join(services)}")
    else:
        bad('no "Claude Code-credentials" item in the Keychain (the claude CLI saves it after /login with a Claude account)')
    if creds is None:
        for service in [s for s in services if s.startswith("Claude Code-credentials")] or ["Claude Code-credentials"]:
            secret, error = keychain_secret(service)
            if secret:
                try:
                    creds = json.loads(secret)
                    ok(f'read "{service}" from the Keychain')
                    break
                except json.JSONDecodeError:
                    warn(f'"{service}" isn\'t the expected JSON')
            elif services:
                warn(f'couldn\'t read "{service}": {error}')
    if not creds:
        return
    oauth = creds.get("claudeAiOauth") if isinstance(creds, dict) else None
    if not oauth:
        bad("the login has no Claude subscription (claudeAiOauth) part; maybe only MCP logins are stored")
        return
    info(f"plan: {oauth.get('subscriptionType') or 'unknown'}; token expires {when(oauth.get('expiresAt'))}")
    scopes = oauth.get("scopes") or []
    if scopes and "user:profile" not in scopes:
        warn(f"token scopes {scopes} lack user:profile, so the usage endpoint will refuse it")
    status, body = curl(
        "https://api.anthropic.com/api/oauth/usage",
        {"Authorization": f"Bearer {oauth.get('accessToken', '')}", "anthropic-beta": "oauth-2025-04-20", "Accept": "application/json"},
    )
    if status is None and body is None:
        return
    if status == 200:
        data = json.loads(body)
        ok("usage endpoint: " + limits_line([("5-hour", data.get("five_hour")), ("weekly", data.get("seven_day"))]))
    else:
        bad(f"usage endpoint answered {status or 'nothing'}: {(body or '')[:160]}")


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
    if rollouts:
        newest = max(rollouts, key=lambda p: p.stat().st_mtime)
        info(f"newest session log: {when(newest.stat().st_mtime)}")
    auth = read_json(folder / "auth.json")
    if not auth:
        bad("~/.codex/auth.json not found: run codex and sign in")
        return
    if auth.get("OPENAI_API_KEY"):
        warn("auth.json holds an API key (API keys have no plan limits)")
    tokens = auth.get("tokens") or {}
    token = tokens.get("access_token")
    if not token:
        bad("no ChatGPT login tokens in auth.json")
        return
    ok("ChatGPT login found")
    exp = jwt_exp(token)
    info(f"access token expires {when(exp)}; last refreshed {auth.get('last_refresh', 'unknown')}")
    if exp and exp < NOW.timestamp():
        warn("token expired: run codex once and it renews it")
    headers = {"Authorization": f"Bearer {token}", "Accept": "application/json", "User-Agent": "Kvota"}
    if tokens.get("account_id"):
        headers["ChatGPT-Account-Id"] = tokens["account_id"]
    status, body = curl("https://chatgpt.com/backend-api/wham/usage", headers)
    if status is None and body is None:
        return
    if status == 200:
        data = json.loads(body)
        rate = data.get("rate_limit") or {}
        ok(f"usage endpoint ({data.get('plan_type', 'plan unknown')}): "
           + limits_line([("5-hour", rate.get("primary_window")), ("weekly", rate.get("secondary_window"))]))
    else:
        bad(f"usage endpoint answered {status or 'nothing'}: {(body or '')[:160]}")


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
    settings = read_json(folder / "settings.json") or {}
    auth_type = (((settings.get("security") or {}).get("auth") or {}).get("selectedType")
                 or settings.get("selectedAuthType")) if isinstance(settings, dict) else None
    if auth_type:
        info(f"sign-in method: {auth_type}")
        if auth_type in ("gemini-api-key", "vertex-ai"):
            warn("API key / Vertex sign-in: no Code Assist quota to show")
    gemini = shutil.which("gemini")
    info(f"gemini command: {gemini or 'not on PATH in this shell'}")
    creds = read_json(folder / "oauth_creds.json")
    if not creds:
        bad("~/.gemini/oauth_creds.json not found (Google sign-in may be stored in the Keychain or not done)")
        services = keychain_services("gemini")
        if services:
            info(f"Keychain items mentioning gemini: {', '.join(services)}")
        return
    ok("Google sign-in found")
    info(f"access token expires {when(creds.get('expiry_date'))}; refresh token: {'yes' if creds.get('refresh_token') else 'no'}")
    expiry = creds.get("expiry_date") or 0
    if expiry / 1000 < NOW.timestamp():
        warn("access token expired; Kvota renews it using the installed Gemini CLI, or run gemini once")
        return
    status, body = curl(
        "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist",
        {"Authorization": f"Bearer {creds.get('access_token', '')}", "Content-Type": "application/json"},
        method="POST",
        body=json.dumps({"metadata": {"ideType": "IDE_UNSPECIFIED", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"}}),
    )
    if status is None and body is None:
        return
    if status != 200:
        bad(f"loadCodeAssist answered {status or 'nothing'}: {(body or '')[:160]}")
        return
    data = json.loads(body)
    tier = (data.get("paidTier") or data.get("currentTier") or {}).get("name", "unknown")
    project = data.get("cloudaicompanionProject")
    if isinstance(project, dict):
        project = project.get("id")
    status, body = curl(
        "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota",
        {"Authorization": f"Bearer {creds.get('access_token', '')}", "Content-Type": "application/json"},
        method="POST",
        body=json.dumps({"project": project} if project else {}),
    )
    if status == 200:
        buckets = json.loads(body).get("buckets") or []
        summary = ", ".join(
            f"{b.get('modelId')} {100 * float(b.get('remainingFraction', 0)):.0f}% left"
            for b in buckets if b.get("modelId")
        )
        ok(f"quota endpoint ({tier}): {summary or 'no buckets'}")
    else:
        bad(f"retrieveUserQuota answered {status or 'nothing'}: {(body or '')[:160]}")


if __name__ == "__main__":
    print(f"Kvota doctor — {NOW.astimezone():%Y-%m-%d %H:%M}{' (offline)' if OFFLINE else ''}")
    for check in (check_claude, check_codex, check_gemini):
        try:
            check()
        except Exception as error:  # keep going so the other providers are still checked
            bad(f"check failed: {error}")
    print("\nNothing secret was printed. Share this output if you want help reading it.")
