import XCTest
@testable import KvotaCore

final class TimestampTests: XCTestCase {
    func testParsesCommonFormats() throws {
        let expected = Date(timeIntervalSince1970: 1_761_380_130.123)
        XCTAssertEqual(try XCTUnwrap(Timestamp.parse("2025-10-25T08:15:30.123Z")).timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.0005)
        XCTAssertEqual(Timestamp.parse("2025-10-25T08:15:30Z")?.timeIntervalSince1970, 1_761_380_130)
        XCTAssertEqual(Timestamp.parse("2025-10-25T10:15:30+02:00")?.timeIntervalSince1970, 1_761_380_130)
        XCTAssertEqual(Timestamp.parse("2025-10-25T08:15:30.123456789Z").map { Int($0.timeIntervalSince1970) }, 1_761_380_130)
        XCTAssertNil(Timestamp.parse("yesterday"))
    }

    func testMatchesFoundationAcrossYears() {
        let formatter = ISO8601DateFormatter()
        for seconds in stride(from: 0.0, to: 4_102_444_800.0, by: 86_399.0 * 37) {
            let date = Date(timeIntervalSince1970: seconds)
            XCTAssertEqual(Timestamp.parse(formatter.string(from: date)), date)
        }
    }
}

final class ClaudeParserTests: XCTestCase {
    func testParsesAssistantUsage() throws {
        var state = ParserState()
        let line = Lines.claude(id: "msg_1", at: Date(timeIntervalSince1970: 1_761_000_000))
        let parsed = line.utf8CString.withUnsafeBytes { raw in
            ClaudeLogParser.parse(line: UnsafeRawBufferPointer(rebasing: raw.dropLast()), state: &state)
        }
        guard case let .usage(event)? = parsed else { return XCTFail("expected usage") }
        XCTAssertEqual(event.model, "claude-sonnet-4-5-20250929")
        XCTAssertEqual(event.counts, TokenCounts(input: 100, output: 50, cacheRead: 1000, cacheWrite: 200))
        XCTAssertEqual(event.dedupeKey, "claude:msg_1:req_1")
    }

    func testIgnoresUserLinesThatMentionUsage() {
        var state = ParserState()
        let line = Lines.claudeUser(at: Date())
        let parsed = line.utf8CString.withUnsafeBytes { raw in
            ClaudeLogParser.parse(line: UnsafeRawBufferPointer(rebasing: raw.dropLast()), state: &state)
        }
        XCTAssertNil(parsed)
    }
}

final class CodexParserTests: XCTestCase {
    func testRateLimitsWithAbsoluteAndRelativeResets() throws {
        let now = Date(timeIntervalSince1970: 1_761_000_000)
        let absolute = try XCTUnwrap(CodexLogParser.parseRateLimits([
            "primary": ["used_percent": 23.0, "window_minutes": 300, "resets_at": 1_761_003_600],
            "secondary": ["used_percent": 61.5, "window_minutes": 10080, "resets_at": 1_761_400_000],
            "plan_type": "pro",
        ], capturedAt: now))
        XCTAssertEqual(absolute.windows.map(\.label), ["5-hour", "Weekly"])
        XCTAssertEqual(absolute.windows[0].resetsAt, Date(timeIntervalSince1970: 1_761_003_600))
        XCTAssertEqual(absolute.plan, "Pro")
        XCTAssertEqual(absolute.mostConstrained(at: now)?.id, "weekly")

        let relative = try XCTUnwrap(CodexLogParser.parseRateLimits([
            "primary": ["used_percent": 5, "window_minutes": 300, "resets_in_seconds": 600],
        ], capturedAt: now))
        XCTAssertEqual(relative.windows.first?.resetsAt, now.addingTimeInterval(600))

        XCTAssertNil(CodexLogParser.parseRateLimits([
            "limit_id": "codex_bengalfox",
            "primary": ["used_percent": 5, "window_minutes": 300],
        ], capturedAt: now))
    }

    func testExpiredWindowCountsAsReset() {
        let window = LimitWindow(id: "session", label: "5-hour", usedPercent: 90, resetsAt: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(window.usedPercent(at: Date(timeIntervalSince1970: 50)), 90)
        XCTAssertEqual(window.usedPercent(at: Date(timeIntervalSince1970: 200)), 0)

        let snapshot = LimitsSnapshot(provider: .claude, windows: [window], capturedAt: Date(timeIntervalSince1970: 0), source: .statusLine)
        XCTAssertEqual(snapshot.mostConstrained(at: Date(timeIntervalSince1970: 50))?.id, "session")
        XCTAssertNil(snapshot.mostConstrained(at: Date(timeIntervalSince1970: 200)))
    }
}

final class LimitParsingTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_761_000_000)

    func testClaudeStatusLineSnapshot() throws {
        let json = #"{"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1761003600},"seven_day":{"used_percentage":41.2,"resets_at":1761400000}}}"#
        let snapshot = try XCTUnwrap(ClaudeLimits.parseStatusLine(Data(json.utf8), capturedAt: now))
        XCTAssertEqual(snapshot.windows.map(\.id), ["session", "weekly"])
        XCTAssertEqual(snapshot.windows[0].usedPercent, 23.5)
        XCTAssertEqual(snapshot.windows[1].resetsAt, Date(timeIntervalSince1970: 1_761_400_000))
        XCTAssertEqual(snapshot.source, .statusLine)

        let bare = #"{"five_hour":{"used_percentage":10,"resets_at":1761003600}}"#
        XCTAssertEqual(ClaudeLimits.parseStatusLine(Data(bare.utf8), capturedAt: now)?.windows.count, 1)
        XCTAssertNil(ClaudeLimits.parseStatusLine(Data("{}".utf8), capturedAt: now))
    }
}

final class PricingAndFormatTests: XCTestCase {
    func testPriceLookup() throws {
        XCTAssertNotNil(Pricing.price(for: "claude-sonnet-4-5-20250929"))
        XCTAssertNotNil(Pricing.price(for: "claude-opus-4-5[1m]"))
        XCTAssertNotNil(Pricing.price(for: "gpt-5.1-codex-max"))
        XCTAssertNotNil(Pricing.price(for: "gemini-2.5-pro"))
        XCTAssertNotNil(Pricing.price(for: "gemini-3-pro-preview"), "family fallback")
        XCTAssertNil(Pricing.price(for: "totally-unknown-model"))

        let sonnet = try XCTUnwrap(Pricing.price(for: "claude-sonnet-4-5"))
        let cost = sonnet.cost(of: TokenCounts(input: 1_000_000, output: 1_000_000))
        XCTAssertEqual(cost, 18, accuracy: 0.001)
    }

    func testFormatting() {
        XCTAssertEqual(Format.tokens(950), "950")
        XCTAssertEqual(Format.tokens(1_000), "1K")
        XCTAssertEqual(Format.tokens(12_345), "12K")
        XCTAssertEqual(Format.tokens(4_560_000), "4.6M")
        XCTAssertEqual(Format.cost(0.004), "<$0.01")
        XCTAssertEqual(Format.cost(4.1), "$4.10")
        XCTAssertEqual(Format.cost(1240.4), "$1,240")
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(Format.countdown(to: now.addingTimeInterval(45 * 60), from: now), "45m")
        XCTAssertEqual(Format.countdown(to: now.addingTimeInterval(2 * 3600 + 14 * 60), from: now), "2h 14m")
        XCTAssertEqual(Format.countdown(to: now.addingTimeInterval(3 * 86_400 + 4 * 3600), from: now), "3d 4h")
        XCTAssertEqual(Format.modelName("claude-opus-4-5-20251101"), "Opus 4.5")
        XCTAssertEqual(Format.modelName("claude-3-5-sonnet-20241022"), "Sonnet 3.5")
        XCTAssertEqual(Format.modelName("gpt-5.1-codex-max"), "GPT-5.1 Codex Max")
        XCTAssertEqual(Format.modelName("gemini-2.5-pro"), "Gemini 2.5 Pro")
    }
}
