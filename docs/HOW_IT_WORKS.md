# How Kvota reads your usage

Kvota reads what the three CLIs already keep on your Mac. It never asks for a password
or an API key, never reads a CLI's sign-in, and never connects to the internet.

| | Claude Code | Codex CLI | Gemini CLI |
|---|---|---|---|
| **Token usage** | `~/.claude/projects/**/*.jsonl`: `message.usage` on assistant lines | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` (`.jsonl.zst` after a week): `token_count` events | `~/.gemini/tmp/<project>/chats/session-*.jsonl` (older: `.json`): `tokens` on `gemini` messages |
| **Limits** | Claude Code's status line data, saved by Kvota's bridge (below) | Written into the same rollout files: `rate_limits.primary` (5-hour) and `secondary` (weekly) | Not stored on your Mac, so not shown |

## Limits

- **Codex** writes your account's current limits into its session log with every
  reply, so Kvota shows the 5-hour and weekly windows without any setup.
- **Claude** limits are shared by everything on your plan: Claude chat, the desktop
  app, cloud sessions and Claude Code. Claude Code hands the account-wide numbers to
  *status line* commands (documented: `rate_limits.five_hour` and `seven_day`, for Pro
  and Max plans, after the first reply in a session). Kvota can install a tiny shell
  script as your status line command. It saves that part of the data to
  `~/.claude/kvota/rate_limits.json` and then runs your previous status line command,
  so your terminal looks the same. Disconnecting restores your original configuration
  (a backup of `settings.json` is kept as `settings.json.kvota-backup`).
  The numbers update each time you use the `claude` command on this Mac.
- **Gemini CLI** keeps no local copy of its quota. Kvota shows its token usage only.

Kvota never guesses a limit. A reading stays on screen with its age and a countdown
to each reset; once a window has reset, Kvota says so ("new window") until the tool
reports again, because what was used since is unknown.

Anthropic doesn't allow third-party apps to use Claude sign-ins or session tokens
([Claude Code: legal and compliance](https://code.claude.com/docs/en/legal-and-compliance)),
so Kvota doesn't read Claude Code's login, claude.ai cookies, or any other sign-in, and
doesn't call providers' usage endpoints. The status line is the documented way Claude
Code shares limits with other programs.

## Token usage

Token counts come from the logs on this Mac, so they cover the CLIs as you run them
here. Claude chat and Claude Code cloud sessions run on Anthropic's servers and leave no
logs on your Mac: they count toward your limits (which the status line reports), but
not toward Kvota's token totals.

## Efficiency

- **No polling.** Kvota watches the log folders with FSEvents; the kernel batches
  changes, and Kvota wakes at most every two seconds while a CLI is writing. A rescan
  every five minutes is a safety net (unchanged files cost one `stat`).
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

## Troubleshooting

`scripts/kvota-doctor.py` checks what Kvota can find for each tool. Like Kvota, it only
looks at local files and never prints a secret:

```sh
python3 scripts/kvota-doctor.py
```
