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

    /// Parses the response of Claude Code's own usage endpoint
    /// (`GET https://api.anthropic.com/api/oauth/usage`, used by its `/usage` screen).
    /// `utilization` is 0–100 and `resets_at` is ISO-8601.
    public static func parseOAuthUsage(_ data: Data, capturedAt: Date, plan: String? = nil) -> LimitsSnapshot? {
        guard let root = JSON.object(data) else { return nil }
        var windows: [LimitWindow] = []

        func add(_ key: String, id: String, label: String, duration: TimeInterval?) {
            guard let window = root[key] as? [String: Any],
                  let used = JSON.double(window["utilization"]) else { return }
            windows.append(LimitWindow(
                id: id, label: label, usedPercent: used,
                resetsAt: JSON.date(window["resets_at"]), duration: duration
            ))
        }

        add("five_hour", id: "session", label: "5-hour", duration: 5 * 3600)
        add("seven_day", id: "weekly", label: "Weekly", duration: 7 * 86_400)
        // Model-specific weekly windows: seven_day_opus, seven_day_sonnet, …
        for key in root.keys.sorted() where key.hasPrefix("seven_day_") {
            let model = key.dropFirst("seven_day_".count)
            guard !model.isEmpty, !["oauth_apps", "routines", "cowork"].contains(String(model)) else { continue }
            add(key, id: "weekly-\(model)", label: "\(model.prefix(1).uppercased() + model.dropFirst()) weekly", duration: 7 * 86_400)
        }

        var detail: String?
        if let extra = root["extra_usage"] as? [String: Any], JSON.bool(extra["is_enabled"]) == true,
           let used = JSON.double(extra["utilization"]) {
            detail = String(format: "Extra usage %.0f%% of monthly limit", used)
        }
        guard !windows.isEmpty else { return nil }
        return LimitsSnapshot(provider: .claude, windows: windows, plan: plan, capturedAt: capturedAt, source: .live, detail: detail)
    }

    /// `subscriptionType` from Claude Code's credentials ("pro", "max", …) to a display name.
    public static func planName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "max": return "Max"
        case "pro": return "Pro"
        case "team": return "Team"
        case "enterprise": return "Enterprise"
        default: return raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }
}

/// Claude Code's login, as stored in `~/.claude/.credentials.json` (Linux) or the
/// "Claude Code-credentials" Keychain item (macOS).
public struct ClaudeCredentials: Equatable, Sendable {
    public var accessToken: String
    public var expiresAt: Date?
    public var subscriptionType: String?

    public static func parse(_ data: Data) -> ClaudeCredentials? {
        guard let root = JSON.object(data),
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = JSON.string(oauth["accessToken"]) else { return nil }
        return ClaudeCredentials(
            accessToken: token,
            expiresAt: JSON.date(oauth["expiresAt"]),
            subscriptionType: JSON.string(oauth["subscriptionType"])
        )
    }

    public func isExpired(at now: Date, leeway: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) < leeway
    }
}
