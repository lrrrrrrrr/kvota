# How Kvota reads your usage

Kvota never asks for a password or an API key. It reads what the three CLIs already
keep on your Mac. The direct-download build can also ask OpenAI and Google for your
current Codex and Gemini limits using the login those CLIs already have (on by default,
switchable per provider). Claude limits come only from Claude Code's documented status
line data: Anthropic doesn't allow third-party apps to use Claude sign-in tokens, so
Kvota never reads or sends them.

| | Claude Code | Codex CLI | Gemini CLI |
|---|---|---|---|
| **Token usage** | `~/.claude/projects/**/*.jsonl` — `message.usage` on assistant lines | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` (`.jsonl.zst` after a week) — `token_count` events | `~/.gemini/tmp/<project>/chats/session-*.jsonl` (older: `.json`) — `tokens` on `gemini` messages |
| **Limits, local** | Status line bridge (below) | Written into the same rollout files: `rate_limits.primary` (5-hour) and `secondary` (weekly) | Not stored locally |
| **Limits, live** (direct build) | Not used (see above) | `GET chatgpt.com/backend-api/wham/usage` with the Codex CLI login | `POST cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota` with the Gemini CLI login |

## Why this approach

There were three ways to get the numbers:

1. **Ask the CLI** (run `claude /usage`, `codex /status`, `gemini /stats` in a hidden
   terminal and scrape the screen). Slow, starts heavy processes, breaks whenever the
   CLI's screen layout changes, and doesn't work in the App Store sandbox.
2. **Call the providers' usage endpoints** with the CLI's login. Accurate and current,
   but the endpoints are internal and can change, and it needs the user's tokens.
3. **Read local files** the CLIs already write. Free, instant, private, works offline
   and inside the sandbox.

Kvota is built on (3) and offers (2) as an opt-in extra:

- **Codex** is the easy case: every `token_count` event in its session log carries the
  account's current rate limits, so Kvota shows 5-hour and weekly usage without any
  network call.
- **Claude Code** doesn't log limits, but it does hand them to *status line* commands
  (documented: `rate_limits.five_hour` / `seven_day`, for Pro and Max subscribers).
  Kvota can install a tiny shell script as your status line command. It saves that
  part of the data to `~/.claude/kvota/rate_limits.json` and then runs your previous
  status line command, so your terminal looks the same. Removing it from Kvota's
  settings restores your original configuration (a backup of `settings.json` is kept
  as `settings.json.kvota-backup`).
- **Gemini CLI** keeps no local copy of its quota, so limits need the live option.
  Token usage still comes from its local chat recordings.

## Efficiency

- **No polling.** Kvota watches the log folders with FSEvents; the kernel batches
  changes, and Kvota wakes at most every two seconds while a CLI is writing.
- **Incremental reads.** For each file Kvota remembers how far it has read and reads
  only the new bytes. Lines are filtered by a byte search before any JSON decoding.
- **Small memory footprint.** Usage is kept as per-model totals in 15-minute buckets
  for the last 35 days, not as individual messages.
- **De-duplication.** Claude Code writes a reply in several lines and copies history
  into resumed sessions; Kvota counts each request once (by message and request id).
  Codex repeats `token_count` when only the limits change; those are skipped.

## Costs

Costs are estimates at public API list prices (from LiteLLM's price list, refreshed
with `make pricing`). On a subscription you don't pay per token; the number shows the
API-equivalent value of what you used.

## Live limits: what is sent where

| Provider | Credential read | Request |
|---|---|---|
| Codex | `~/.codex/auth.json`, or the "Codex Auth" Keychain item when Codex stores its login there | `GET https://chatgpt.com/backend-api/wham/usage` |
| Gemini | `~/.gemini/oauth_creds.json`, or the "gemini-cli-oauth" Keychain item | `POST https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist` and `:retrieveUserQuota` |

Keychain items are read with macOS's `security` tool, so macOS asks you once whether to
allow it. Claude has no row here on purpose.

Tokens stay in memory and are never written anywhere. If Gemini's one-hour token has
expired, Kvota renews it in memory using the public OAuth client of the Gemini CLI
installed on your Mac, exactly as the CLI itself would. Kvota never renews or rewrites
the Codex login; if it has expired, run codex once.

## Troubleshooting

`scripts/kvota-doctor.py` checks what Kvota can find for each tool and prints only
yes/no, expiry dates and HTTP status codes, never a secret:

```sh
python3 scripts/kvota-doctor.py
```
