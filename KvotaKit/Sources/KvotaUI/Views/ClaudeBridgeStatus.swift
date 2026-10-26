import Foundation
import KvotaCore

/// Explains where the Claude status line bridge is, so "no limits" always has a reason.
enum ClaudeBridgeStatus {
    /// Why Claude Code can't share Claude plan limits with Kvota, when the setup shows it:
    /// its settings send it to another provider, or it's only used where status lines
    /// don't run (the Claude desktop app, IDE extensions, cloud sessions).
    static func blocker(routedTo: String?, clients: [String: Date]) -> (message: String, short: String)? {
        let usageHint = "Kvota shows your token usage; your limits are in Claude under Settings → Usage."
        let terminalOnly = !clients.isEmpty && clients["cli"] == nil
        let names = clients.sorted { $0.value > $1.value }.map { appName($0.key) }
        let list = names.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: " and ")
        switch (routedTo, terminalOnly) {
        case let (host?, true):
            return (
                "This week you used Claude Code only in \(list), which doesn't share your limits with other apps. The claude command in Terminal could, but its settings (~/.claude/settings.json, env) send it to \(host) instead of your Claude plan. \(usageHint)",
                "limits only in Claude's Usage page"
            )
        case let (host?, false):
            return (
                "Claude Code's settings (~/.claude/settings.json, env) send the claude command to \(host) instead of your Claude plan, so it has no Claude limits to share. \(usageHint)",
                "claude uses \(host)"
            )
        case (nil, true):
            return (
                "This week you used Claude Code only in \(list), which doesn't share your limits with other apps (only the claude command in Terminal does). \(usageHint)",
                "limits only in Claude's Usage page"
            )
        case (nil, false):
            return nil
        }
    }

    static func appName(_ client: String) -> String {
        switch client {
        case "cli": "the claude command"
        case "claude-desktop": "the Claude desktop app"
        case "claude-vscode": "VS Code"
        case "claude-jetbrains": "JetBrains IDEs"
        default:
            if client.hasPrefix("sdk") { return "apps built with the Claude Agent SDK" }
            if client.hasPrefix("remote") { return "cloud sessions" }
            return "other apps"
        }
    }

    static func message(for run: StatusLineRun?, now: Date) -> String {
        guard let run else {
            return "Waiting for Claude Code. Open Terminal, run claude and send a message: Claude Code then shares your limits. Only the claude command runs status lines, not the Claude desktop app or the web."
        }
        let when = Format.ago(run.at, now: now)
        if run.hadRateLimits {
            return "Claude Code shared your limits \(when); reading them…"
        }
        if !run.replied {
            return "Claude Code is connected (last started \(when)). Your limits arrive with its first reply: send a message in claude."
        }
        let version = run.claudeCodeVersion.map { " (Claude Code \($0))" } ?? ""
        return "Claude Code replied \(when)\(version) but shared no plan limits. It only shares them when signed in with a Claude Pro or Max plan, not an API key or another provider; type /status in claude to check."
    }

    /// A few words for the compact widget.
    static func short(for run: StatusLineRun?) -> String {
        guard let run else { return "send a message in claude" }
        if run.hadRateLimits { return "reading limits…" }
        return run.replied ? "no plan limits shared" : "send a message in claude"
    }
}
