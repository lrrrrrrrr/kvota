import Foundation
import KvotaCore

/// Explains where the Claude status line bridge is, so "no limits" always has a reason.
enum ClaudeBridgeStatus {
    static func message(for run: StatusLineRun?, now: Date) -> String {
        guard let run else {
            return "Waiting for Claude Code. Start claude in Terminal (if it was already open when you connected, type /exit and start it again) and send a message. The Claude desktop app doesn't run status lines."
        }
        let when = Format.ago(run.at, now: now)
        if run.hadRateLimits {
            return "Claude Code shared your limits \(when); reading them…"
        }
        let version = run.claudeCodeVersion.map { " (Claude Code \($0))" } ?? ""
        return "Claude Code ran the status line \(when)\(version) but shared no plan limits. It only shares them when signed in with a Claude Pro or Max plan, not an API key or another provider; type /status in claude to check. If you are on Pro or Max, update Claude Code."
    }

    /// A few words for the compact widget.
    static func short(for run: StatusLineRun?) -> String {
        guard let run else { return "send a message in claude" }
        return run.hadRateLimits ? "reading limits…" : "no plan limits shared"
    }
}
