import Foundation

/// One model request found in a log file.
struct UsageEvent: Equatable {
    var timestamp: Date
    var model: String
    var counts: TokenCounts
    /// Stable id for de-duplication across lines and files, when the log has one.
    var dedupeKey: String?
    /// The app that wrote the line, when the log says (Claude Code's `entrypoint`, such as
    /// "cli" for the claude command or "claude-desktop" for the Claude desktop app).
    var client: String? = nil
}

/// Parser state that has to survive between incremental reads of the same file.
struct ParserState: Equatable {
    // Codex: the model is announced in `turn_context` lines, usage arrives later.
    var currentModel: String?
    var lastTotalTokens: Int64 = -1
    var lastTotals: TokenCounts?
}

/// Things a parser can report for a line.
enum ParsedLine {
    case usage(UsageEvent)
    case limits(LimitsSnapshot)
    case usageAndLimits(UsageEvent, LimitsSnapshot)
}

protocol LogLineParser {
    /// Cheap byte-level filter: lines without any of these substrings are skipped undecoded.
    static var needles: [[UInt8]] { get }
    static func parse(_ object: [String: Any], state: inout ParserState) -> ParsedLine?
}

extension LogLineParser {
    static func parse(line: UnsafeRawBufferPointer, state: inout ParserState) -> ParsedLine? {
        guard LineScanner.containsAny(line, needles), let object = JSON.object(line) else { return nil }
        return parse(object, state: &state)
    }
}
