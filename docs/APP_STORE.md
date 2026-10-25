# Publishing Kvota on the Mac App Store

The repository builds two apps from the same code:

| Target | Distribution | Sandbox | Network |
|---|---|---|---|
| `Kvota` | GitHub Releases, Homebrew | No (hardened runtime) | None |
| `KvotaAppStore` | Mac App Store | Yes | None |

Both read local files only. The App Store build reaches them through folders the user
picks once in an open panel (security-scoped bookmarks). Neither touches a sign-in or a
provider's servers, which keeps it clear of App Review questions about third-party
services and tokens.

## One-time setup

1. Join the Apple Developer Program.
2. In Certificates, Identifiers & Profiles, register an App ID, for example
   `com.yourname.kvota`.
3. Create the app in App Store Connect (platform macOS, the same bundle ID,
   primary category **Developer Tools**).
4. Create `Config/Local.xcconfig` (git-ignored):

   ```
   KVOTA_TEAM_ID = ABCDE12345
   KVOTA_BUNDLE_ID = com.yourname.kvota
   ```

5. `make project`, open `Kvota.xcodeproj`, select the **KvotaAppStore** scheme.

## Each release

1. Bump `MARKETING_VERSION` (and `CURRENT_PROJECT_VERSION`) in `Config/Kvota.xcconfig`.
2. Product → Archive with the **KvotaAppStore** scheme.
3. In the Organizer: Distribute App → App Store Connect → Upload.
4. In App Store Connect, add the build to a new version and submit for review.

## Listing text (suggested)

- **Name:** Kvota
- **Subtitle:** AI coding limits at a glance
- **Keywords:** claude,codex,gemini,usage,limits,tokens,quota,menu bar,widget,ai,developer
- **Promotional text:** See how much of your Claude Code, Codex and Gemini limits you have
  left — in the menu bar and in a small widget that floats over your work.
- **Description:**

  Kvota keeps your AI coding limits in view. It reads the usage data that Claude Code,
  Codex CLI and Gemini CLI already store on your Mac and shows it in the menu bar and in
  a compact floating widget.

  • 5-hour and weekly limits with reset countdowns (Codex and Claude Code)
  • Tokens used today and this week, per model, with API-equivalent cost estimates
  • A small, draggable widget that stays above your windows, fades when you're not
    looking at it, and can be made click-through
  • Alerts before you hit a limit
  • No accounts, no API keys, no network access: everything stays on your Mac

  The first time, Kvota asks you to select each tool's folder (~/.claude, ~/.codex,
  ~/.gemini) so it can read the logs. Claude Code limits need Kvota's optional status
  line bridge, which you can connect from Settings.

  Kvota is open source: github.com/lrrrrrrrr/kvota

## App Privacy

- **Data collection:** Data Not Collected.
- The app includes `PrivacyInfo.xcprivacy` declaring UserDefaults (`CA92.1`) and file
  timestamps of user-selected files (`3B52.1`).
- Export compliance: no encryption (`ITSAppUsesNonExemptEncryption = NO`).

## Notes for App Review

> Kvota is a menu bar utility for developers who use the Claude Code, Codex and Gemini
> command-line tools. It reads the usage logs these tools write in the user's home folder.
> On first launch the user grants access to each folder through the standard open panel.
> The app makes no network connections. "Connect status line" (Settings → Providers)
> writes a small script into the user-selected ~/.claude folder and registers it in
> ~/.claude/settings.json so Claude Code shares limit data with Kvota; "Disconnect"
> restores the previous configuration. To test without these tools, the app still runs and
> shows empty states.

## Screenshots

`docs/screenshots/hero-dark.jpg` and `hero-light.jpg` are 2880×1800, one of the sizes
App Store Connect accepts for Mac apps, and contain only sample data on a generated
wallpaper. The `Screenshots` workflow regenerates them from the current UI; run it from
the Actions tab before a release. For more variants, add scenes to
`scripts/compose-screenshots.py`.
