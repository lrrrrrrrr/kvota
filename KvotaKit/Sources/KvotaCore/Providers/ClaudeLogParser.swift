import Foundation

/// Reads Claude Code transcripts: `~/.claude/projects/<project>/<session>.jsonl`.
///
/// Each assistant reply is written as one or more lines that share `message.id`
/// and carry `message.usage`. Resumed sessions copy earlier lines into a new file,
/// so lines are de-duplicated by message id and request id.
enum ClaudeLogParser: LogLineParser {
    static let needles: [[UInt8]] = [Array(literal: "\"usage\"")]

    static func parse(_ object: [String: Any], state: inout ParserState) -> ParsedLine? {
        guard JSON.string(object["type"]) == "assistant",
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let timestamp = JSON.string(object["timestamp"]).flatMap(Timestamp.parse)
        else { return nil }

        let model = JSON.string(message["model"]) ?? "claude"
        if model == "<synthetic>" { return nil }

        let counts = TokenCounts(
            input: JSON.int(usage["input_tokens"]),
            output: JSON.int(usage["output_tokens"]),
            cacheRead: JSON.int(usage["cache_read_input_tokens"]),
            cacheWrite: JSON.int(usage["cache_creation_input_tokens"])
        )
        if counts.isZero { return nil }

        var key: String?
        if let messageID = JSON.string(message["id"]) {
            key = "claude:" + messageID + ":" + (JSON.string(object["requestId"]) ?? "")
        }
        return .usage(UsageEvent(timestamp: timestamp, model: model, counts: counts, dedupeKey: key))
    }
}
