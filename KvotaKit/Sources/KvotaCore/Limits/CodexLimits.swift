import Foundation

public enum CodexLimits {
    /// Parses ChatGPT's Codex usage endpoint (`GET https://chatgpt.com/backend-api/wham/usage`).
    ///
    /// ```json
    /// {"plan_type": "plus",
    ///  "rate_limit": {"primary_window": {"used_percent": 12, "limit_window_seconds": 18000, "reset_at": 1761500000},
    ///                 "secondary_window": {...}},
    ///  "credits": {"has_credits": false, "unlimited": false, "balance": "0"}}
    /// ```
    public static func parseUsage(_ data: Data, capturedAt: Date) -> LimitsSnapshot? {
        guard let root = JSON.object(data) else { return nil }
        let rateLimit = (root["rate_limit"] as? [String: Any]) ?? (root["rate_limits"] as? [String: Any]) ?? [:]

        var windows: [LimitWindow] = []
        for (key, id, fallback) in [("primary_window", "session", "5-hour"), ("secondary_window", "weekly", "Weekly")] {
            guard let window = rateLimit[key] as? [String: Any],
                  let used = JSON.double(window["used_percent"]) else { continue }
            let seconds = JSON.double(window["limit_window_seconds"])
            var resetsAt = JSON.date(window["reset_at"]) ?? JSON.date(window["resets_at"])
            if resetsAt == nil, let after = JSON.double(window["reset_after_seconds"]) {
                resetsAt = capturedAt.addingTimeInterval(after)
            }
            windows.append(LimitWindow(
                id: id,
                label: seconds.map { CodexLogParser.windowLabel(minutes: Int($0 / 60)) } ?? fallback,
                usedPercent: used,
                resetsAt: resetsAt,
                duration: seconds
            ))
        }
        guard !windows.isEmpty else { return nil }

        var detail: String?
        if let credits = root["credits"] as? [String: Any], JSON.bool(credits["has_credits"]) == true {
            if JSON.bool(credits["unlimited"]) == true {
                detail = "Unlimited credits"
            } else if let balance = JSON.string(credits["balance"]) ?? JSON.double(credits["balance"]).map({ String(format: "%.0f", $0) }) {
                detail = "Credits: \(balance)"
            }
        }
        return LimitsSnapshot(
            provider: .codex,
            windows: windows,
            plan: JSON.string(root["plan_type"]).map(CodexLogParser.planName),
            capturedAt: capturedAt,
            source: .live,
            detail: detail
        )
    }
}

/// Codex CLI's login file, `~/.codex/auth.json`.
public struct CodexCredentials: Equatable, Sendable {
    public var accessToken: String
    public var accountID: String?
    /// From the access token's `exp` claim, when it is a readable JWT.
    public var expiresAt: Date?

    public init(accessToken: String, accountID: String?, expiresAt: Date? = nil) {
        self.accessToken = accessToken
        self.accountID = accountID
        self.expiresAt = expiresAt
    }

    public static func parse(_ data: Data) -> CodexCredentials? {
        guard let root = JSON.object(data),
              let tokens = root["tokens"] as? [String: Any],
              let token = JSON.string(tokens["access_token"]) else { return nil }
        return CodexCredentials(
            accessToken: token,
            accountID: JSON.string(tokens["account_id"]),
            expiresAt: JWT.expiry(token)
        )
    }

    public func isExpired(at now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }
}

/// Reads claims from a JWT without verifying it (only to know when a token expires).
enum JWT {
    static func expiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64), let claims = JSON.object(data) else { return nil }
        return JSON.date(claims["exp"])
    }
}
