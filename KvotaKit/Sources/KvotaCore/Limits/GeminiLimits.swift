import Foundation

public enum GeminiLimits {
    /// Parses Gemini Code Assist's `retrieveUserQuota` response: one bucket per model with
    /// the remaining share of its daily request quota.
    ///
    /// ```json
    /// {"buckets": [{"modelId": "gemini-2.5-pro", "tokenType": "REQUESTS",
    ///               "remainingFraction": 0.75, "resetTime": "2025-10-22T16:01:15Z"}]}
    /// ```
    public static func parseQuota(_ data: Data, capturedAt: Date, plan: String? = nil) -> LimitsSnapshot? {
        guard let root = JSON.object(data), let buckets = root["buckets"] as? [[String: Any]] else { return nil }

        // Several buckets can exist per model (token types); keep the most constrained.
        var byModel: [String: LimitWindow] = [:]
        for bucket in buckets {
            guard let model = JSON.string(bucket["modelId"]),
                  let remaining = JSON.double(bucket["remainingFraction"]) else { continue }
            let used = (1 - min(max(remaining, 0), 1)) * 100
            let window = LimitWindow(
                id: "model-\(model)",
                label: displayName(forModel: model),
                usedPercent: used,
                resetsAt: JSON.date(bucket["resetTime"]),
                duration: 86_400
            )
            if let existing = byModel[model], existing.usedPercent >= used { continue }
            byModel[model] = window
        }
        guard !byModel.isEmpty else { return nil }

        let windows = byModel.values.sorted { lhs, rhs in
            let l = rank(lhs.id), r = rank(rhs.id)
            return l != r ? l < r : lhs.label < rhs.label
        }
        return LimitsSnapshot(provider: .gemini, windows: windows, plan: plan, capturedAt: capturedAt, source: .live)
    }

    /// "gemini-2.5-pro" → "2.5 Pro", "gemini-3-flash-preview" → "3 Flash Preview".
    public static func displayName(forModel model: String) -> String {
        var name = model.lowercased()
        if name.hasPrefix("gemini-") { name.removeFirst("gemini-".count) }
        return name.split(separator: "-").map { part -> String in
            part.first?.isLetter == true ? part.prefix(1).uppercased() + part.dropFirst() : String(part)
        }.joined(separator: " ")
    }

    private static func rank(_ id: String) -> Int {
        if id.contains("pro") { return 0 }
        if id.contains("flash-lite") { return 2 }
        if id.contains("flash") { return 1 }
        return 3
    }

    /// Plan name from `loadCodeAssist` (`paidTier` wins over `currentTier`).
    public static func parsePlan(_ data: Data) -> (plan: String?, project: String?) {
        guard let root = JSON.object(data) else { return (nil, nil) }
        let paid = root["paidTier"] as? [String: Any]
        let current = root["currentTier"] as? [String: Any]
        var plan = JSON.string(paid?["name"]) ?? JSON.string(current?["name"])
        if plan == nil, let id = JSON.string(paid?["id"]) ?? JSON.string(current?["id"]) {
            switch id {
            case "free-tier": plan = "Free"
            case "standard-tier": plan = "Standard"
            case "legacy-tier": plan = "Legacy"
            default: plan = id
            }
        }
        var project = JSON.string(root["cloudaicompanionProject"])
        if project == nil, let object = root["cloudaicompanionProject"] as? [String: Any] {
            project = JSON.string(object["id"])
        }
        return (plan, project)
    }
}

/// Gemini CLI's login file, `~/.gemini/oauth_creds.json`.
public struct GeminiCredentials: Equatable, Sendable {
    public var accessToken: String?
    public var refreshToken: String?
    public var expiresAt: Date?

    public static func parse(_ data: Data) -> GeminiCredentials? {
        guard let root = JSON.object(data) else { return nil }
        // Newer Gemini CLIs keep the login in the Keychain ("gemini-cli-oauth") as
        // {"serverName": ..., "token": {"accessToken", "refreshToken", "expiresAt"}}.
        if let token = root["token"] as? [String: Any] {
            let creds = GeminiCredentials(
                accessToken: JSON.string(token["accessToken"]),
                refreshToken: JSON.string(token["refreshToken"]),
                expiresAt: JSON.date(token["expiresAt"])
            )
            return creds.accessToken == nil && creds.refreshToken == nil ? nil : creds
        }
        let creds = GeminiCredentials(
            accessToken: JSON.string(root["access_token"]),
            refreshToken: JSON.string(root["refresh_token"]),
            expiresAt: JSON.date(root["expiry_date"])
        )
        return creds.accessToken == nil && creds.refreshToken == nil ? nil : creds
    }

    public func hasValidAccessToken(at now: Date, leeway: TimeInterval = 60) -> Bool {
        guard accessToken != nil else { return false }
        guard let expiresAt else { return true }
        return expiresAt.timeIntervalSince(now) > leeway
    }
}
