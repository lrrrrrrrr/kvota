import Foundation
import KvotaCore

/// Explains where the Claude status line bridge is, so "no limits" always has a reason.
enum ClaudeBridgeStatus {
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
