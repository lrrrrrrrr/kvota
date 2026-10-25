import Foundation

/// Reads Gemini CLI chat recordings: `~/.gemini/tmp/<project>/chats/session-*.jsonl`
/// (older versions wrote one `session-*.json` document per session).
///
/// Model replies are records with `"type": "gemini"`, a `model` and a `tokens` summary.
/// A record can be rewritten later with the same `id`, so ids are de-duplicated.
enum GeminiLogParser: LogLineParser {
    static let needles: [[UInt8]] = [Array(literal: "\"tokens\"")]

    static func parse(_ object: [String: Any], state: inout ParserState) -> ParsedLine? {
        event(from: object).map(ParsedLine.usage)
    }

    static func event(from message: [String: Any]) -> UsageEvent? {
        guard JSON.string(message["type"]) == "gemini",
              let tokens = message["tokens"] as? [String: Any],
              let timestamp = JSON.string(message["timestamp"]).flatMap(Timestamp.parse)
        else { return nil }

        let prompt = JSON.int(tokens["input"])
        let cached = JSON.int(tokens["cached"])
        let thoughts = JSON.int(tokens["thoughts"])
        let toolPrompt = JSON.int(tokens["tool"])
        let counts = TokenCounts(
            input: max(0, prompt - cached) + toolPrompt,
            output: JSON.int(tokens["output"]) + thoughts,
            cacheRead: cached,
            cacheWrite: 0,
            reasoning: thoughts
        )
        if counts.isZero { return nil }

        // Message ids are UUIDs, so they are unique without the session id. Leaving the
        // session out keeps keys stable when Gemini CLI converts a legacy .json file to .jsonl.
        let key = JSON.string(message["id"]).map { "gemini:" + $0 }
        return UsageEvent(
            timestamp: timestamp,
            model: JSON.string(message["model"]) ?? "gemini",
            counts: counts,
            dedupeKey: key
        )
    }

    /// Legacy single-document session files.
    static func events(fromDocument data: Data) -> [UsageEvent] {
        guard let root = JSON.object(data), let messages = root["messages"] as? [[String: Any]] else { return [] }
        return messages.compactMap { event(from: $0) }
    }
}
