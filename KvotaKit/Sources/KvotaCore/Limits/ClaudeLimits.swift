import Foundation

/// Parsers for Claude's subscription limits.
public enum ClaudeLimits {
    /// Reads the file written by Kvota's status line bridge: the `rate_limits` object that
    /// Claude Code passes to status line commands (documented, available to Pro and Max
    /// subscribers after the first reply in a session). Accepts either the bare object or
    /// a full status line payload that contains it.
    ///
    /// ```json
    /// {"five_hour": {"used_percentage": 23.5, "resets_at": 1738425600},
    ///  "seven_day": {"used_percentage": 41.2, "resets_at": 1738857600}}
    /// ```
    public static func parseStatusLine(_ data: Data, capturedAt: Date) -> LimitsSnapshot? {
        guard var root = JSON.object(data) else { return nil }
        if let nested = root["rate_limits"] as? [String: Any] { root = nested }

        var windows: [LimitWindow] = []
        let known: [(key: String, id: String, label: String, duration: TimeInterval?)] = [
            ("five_hour", "session", "5-hour", 5 * 3600),
            ("seven_day", "weekly", "Weekly", 7 * 86_400),
            ("spend_limit", "spend", "Spend limit", nil),
        ]
        for entry in known {
            guard let window = root[entry.key] as? [String: Any],
                  let used = JSON.double(window["used_percentage"]) ?? JSON.double(window["utilization"])
            else { continue }
            windows.append(LimitWindow(
                id: entry.id,
                label: entry.label,
                usedPercent: used,
                resetsAt: JSON.date(window["resets_at"]),
                duration: entry.duration
            ))
        }
        guard !windows.isEmpty else { return nil }

        var detail: String?
        if let spend = root["spend_limit"] as? [String: Any],
           let used = JSON.double(spend["used_usd"]), let limit = JSON.double(spend["limit_usd"]) {
            detail = String(format: "$%.2f of $%.0f", used, limit)
        }
        return LimitsSnapshot(provider: .claude, windows: windows, capturedAt: capturedAt, source: .statusLine, detail: detail)
    }
}
