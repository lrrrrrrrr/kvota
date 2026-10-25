import Foundation

/// Reads Codex CLI rollouts: `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`
/// (older ones are compressed to `.jsonl.zst`).
///
/// Lines look like `{"timestamp": "...", "type": "event_msg", "payload": {"type": "token_count", ...}}`.
/// `token_count` events carry the session's cumulative usage, the last turn's usage and,
/// best of all, the account's current rate limits — so Codex limits need no network.
enum CodexLogParser: LogLineParser {
    static let needles: [[UInt8]] = [
        Array(literal: "\"token_count\""),
        Array(literal: "\"turn_context\""),
        Array(literal: "\"session_meta\""),
    ]

    static func parse(_ object: [String: Any], state: inout ParserState) -> ParsedLine? {
        guard let payload = object["payload"] as? [String: Any] else { return nil }
        let lineType = JSON.string(object["type"])

        if lineType == "turn_context" || lineType == "session_meta" {
            if let model = JSON.string(payload["model"]) {
                state.currentModel = model
            }
            return nil
        }

        guard lineType == "event_msg", JSON.string(payload["type"]) == "token_count",
              let timestamp = JSON.string(object["timestamp"]).flatMap(Timestamp.parse)
        else { return nil }

        let event = usageEvent(payload: payload, timestamp: timestamp, state: &state)
        let limits = (payload["rate_limits"] as? [String: Any]).flatMap { parseRateLimits($0, capturedAt: timestamp) }

        switch (event, limits) {
        case let (event?, limits?): return .usageAndLimits(event, limits)
        case let (event?, nil): return .usage(event)
        case let (nil, limits?): return .limits(limits)
        default: return nil
        }
    }

    private static func usageEvent(payload: [String: Any], timestamp: Date, state: inout ParserState) -> UsageEvent? {
        guard let info = payload["info"] as? [String: Any] else { return nil }
        let total = (info["total_token_usage"] as? [String: Any]).map(counts(from:))
        let totalTokens = JSON.int((info["total_token_usage"] as? [String: Any])?["total_tokens"])

        // Codex repeats token_count when only the rate limits changed; skip those.
        if let total, totalTokens > 0, totalTokens == state.lastTotalTokens, total == state.lastTotals {
            return nil
        }

        var turn: TokenCounts?
        if let last = info["last_token_usage"] as? [String: Any] {
            turn = counts(from: last)
        } else if let total, let previous = state.lastTotals {
            turn = total - previous
        } else {
            turn = total
        }
        if let total {
            state.lastTotals = total
            state.lastTotalTokens = totalTokens
        }

        guard let turn, !turn.isZero, turn.input >= 0, turn.output >= 0 else { return nil }
        let model = JSON.string(info["model"]) ?? state.currentModel ?? "gpt-5-codex"
        return UsageEvent(timestamp: timestamp, model: model, counts: turn, dedupeKey: nil)
    }

    /// OpenAI counts cached tokens inside `input_tokens` and reasoning inside `output_tokens`.
    static func counts(from usage: [String: Any]) -> TokenCounts {
        let input = JSON.int(usage["input_tokens"])
        let cached = JSON.int(usage["cached_input_tokens"])
        let cacheWrite = JSON.int(usage["cache_write_input_tokens"])
        return TokenCounts(
            input: max(0, input - cached - cacheWrite),
            output: JSON.int(usage["output_tokens"]),
            cacheRead: cached,
            cacheWrite: cacheWrite,
            reasoning: JSON.int(usage["reasoning_output_tokens"])
        )
    }

    /// `rate_limits` from a token_count event. Only the main Codex limit is used;
    /// model-specific side limits carry a different `limit_id`.
    static func parseRateLimits(_ limits: [String: Any], capturedAt: Date) -> LimitsSnapshot? {
        if let limitID = JSON.string(limits["limit_id"]), limitID != "codex" {
            return nil
        }
        var windows: [LimitWindow] = []
        for (key, id, fallback) in [("primary", "session", "5-hour"), ("secondary", "weekly", "Weekly")] {
            guard let window = limits[key] as? [String: Any],
                  let used = JSON.double(window["used_percent"]) else { continue }
            let minutes = JSON.optionalInt(window["window_minutes"])
            var resetsAt = JSON.date(window["resets_at"])
            if resetsAt == nil, let seconds = JSON.double(window["resets_in_seconds"]) {
                resetsAt = capturedAt.addingTimeInterval(seconds)
            }
            windows.append(LimitWindow(
                id: id,
                label: minutes.map { windowLabel(minutes: Int($0)) } ?? fallback,
                usedPercent: used,
                resetsAt: resetsAt,
                duration: minutes.map { Double($0) * 60 }
            ))
        }
        guard !windows.isEmpty else { return nil }

        var detail: String?
        if let credits = limits["credits"] as? [String: Any], JSON.bool(credits["has_credits"]) == true {
            if JSON.bool(credits["unlimited"]) == true {
                detail = "Unlimited credits"
            } else if let balance = JSON.string(credits["balance"]) ?? JSON.double(credits["balance"]).map({ String(format: "%.0f", $0) }) {
                detail = "Credits: \(balance)"
            }
        }
        return LimitsSnapshot(
            provider: .codex,
            windows: windows,
            plan: JSON.string(limits["plan_type"]).map(planName),
            capturedAt: capturedAt,
            source: .sessionLog,
            detail: detail
        )
    }

    static func windowLabel(minutes: Int) -> String {
        switch minutes {
        case 300: return "5-hour"
        case 1440: return "Daily"
        case 10080: return "Weekly"
        case 43200, 44640: return "Monthly"
        default:
            if minutes % 1440 == 0 { return "\(minutes / 1440)-day" }
            if minutes % 60 == 0 { return "\(minutes / 60)-hour" }
            return "\(minutes)-minute"
        }
    }

    static func planName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "team": return "Team"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        case "edu", "education": return "Edu"
        case "free": return "Free"
        default: return raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }
}
