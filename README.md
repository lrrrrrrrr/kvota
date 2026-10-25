<p align="center">
  <img src="docs/icon.png" width="128" alt="Kvota icon">
</p>

<h1 align="center">Kvota</h1>

<p align="center">
  Your Claude, Codex and Gemini limits at a glance — in the menu bar and in a tiny widget that floats over your work.
</p>

<p align="center">
  <a href="https://github.com/lrrrrrrrr/kvota/actions/workflows/ci.yml"><img src="https://github.com/lrrrrrrrr/kvota/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-111?logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-SwiftUI%20%2B%20AppKit-F05138?logo=swift&logoColor=white" alt="Swift">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT"></a>
</p>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/hero-dark.jpg">
  <img src="docs/screenshots/hero-light.jpg" alt="Kvota's menu bar window and floating widget over an editor">
</picture>

## What it shows

- **5-hour and weekly limits** with countdowns to the reset — Codex from its own session
  logs, Claude Code through an optional status line bridge, Gemini's daily per-model
  quotas with live limits.
- **Tokens used** today, in the last 5 hours, 7 days and this month, per model, with an
  estimated API-equivalent cost.
- **A floating widget** that stays above your windows on every Space, fades when you're
  not looking at it, can sit behind windows or become click-through, and is draggable
  anywhere. Compact (one ring per tool) or detailed (bars and reset times).
- **The menu bar**: an icon with your highest usage, usage per tool, or just the icon.
- **Alerts** when a limit passes your threshold (and again at 95%).

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/widgets-dark.png">
  <img src="docs/screenshots/widgets-light.png" alt="Compact and detailed widget styles">
</picture>

<p align="center"><sub>Compact and detailed widget. Screenshots use sample data.</sub></p>

## How it gets the numbers

No passwords, no API keys. Kvota reads what the CLIs already store on your Mac:

| | Usage | Limits |
|---|---|---|
| **Codex CLI** | `~/.codex/sessions/**/rollout-*.jsonl` | In the same files — every reply logs the 5-hour and weekly limits |
| **Claude Code** | `~/.claude/projects/**/*.jsonl` | Claude Code passes them to status line commands; Kvota's bridge saves them (your status line keeps working) |
| **Gemini CLI** | `~/.gemini/tmp/*/chats/*.jsonl` | Live only: Gemini CLI keeps no local copy |

The direct-download build also fetches **live Codex and Gemini limits** with the login
those CLIs already have (switchable per provider). Claude limits come only from Claude
Code's status line: Kvota never uses Claude sign-in tokens, which Anthropic doesn't allow
third-party apps to do. Details, endpoints and troubleshooting:
[docs/HOW_IT_WORKS.md](docs/HOW_IT_WORKS.md).

## Light on resources

Native Swift (SwiftUI + AppKit), no Electron, no web views. Kvota watches the log
folders with FSEvents instead of polling, reads only the bytes appended since the last
look, and keeps usage as 15-minute per-model totals rather than whole transcripts.

## Install

- **Download** the latest `Kvota-x.y.z.zip` from [Releases](https://github.com/lrrrrrrrr/kvota/releases),
  unzip and move Kvota to Applications.
- **Mac App Store**: coming soon (sandboxed, local files only — see [docs/APP_STORE.md](docs/APP_STORE.md)).
- **From source** (Xcode 16+):

  ```sh
  brew install xcodegen
  git clone https://github.com/lrrrrrrrr/kvota && cd kvota
  make open      # generates Kvota.xcodeproj and opens it; run the "Kvota" scheme
  # or, without Xcode's UI:
  make run       # swift run, straight from the package
  ```

On first launch Kvota opens its settings. For Claude limits, click **Connect** next to
"Status line bridge"; limits appear after Claude Code's next reply.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/settings-dark.png">
    <img src="docs/screenshots/settings-light.png" width="640" alt="Kvota settings: providers">
  </picture>
</p>

## Two builds

| | `Kvota` (direct) | `KvotaAppStore` |
|---|---|---|
| Sandbox | No (hardened runtime) | Yes |
| Folder access | Automatic | You pick `~/.claude`, `~/.codex`, `~/.gemini` once |
| Network | Only for live Codex and Gemini limits | None |
| Live limits | Optional | Not included |

## Project layout

```
KvotaKit/                 Swift package
  Sources/KvotaCore       Log parsers, incremental scanner, limits, pricing (macOS + Linux)
  Sources/KvotaUI         Menu bar, floating widget, settings, app model
  Sources/KvotaLive       Live limits clients (direct build only)
  Tests/                  Parser/engine tests and UI snapshot rendering
App/                      App entry point, Info.plist, entitlements, assets
project.yml               XcodeGen spec for both app targets
scripts/                  Icon and price-table generators
```

`make test` runs the tests; CI runs them on macOS and Linux and builds both apps.
The screenshots are rendered from the real views with sample data on a Mac runner and
composed by `scripts/compose-screenshots.py` (the `Screenshots` workflow keeps them
up to date).

## Related

[CodexBar](https://github.com/steipete/CodexBar) is a mature menu bar app covering many
providers. Kvota is deliberately small: three CLIs, a floating widget, local-first, and an
App Store build.

## License

MIT © 2026 Mykola Sleta
