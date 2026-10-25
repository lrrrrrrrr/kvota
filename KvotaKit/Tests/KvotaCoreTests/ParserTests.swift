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

    func testCodexUsageEndpoint() throws {
        let json = #"""
        {"plan_type":"plus","rate_limit":{"allowed":true,
          "primary_window":{"used_percent":12,"limit_window_seconds":18000,"reset_after_seconds":3600,"reset_at":1761003600},
          "secondary_window":{"used_percent":3,"limit_window_seconds":604800,"reset_at":1761500000}},
         "credits":{"has_credits":true,"unlimited":false,"balance":"250"}}
        """#
        let snapshot = try XCTUnwrap(CodexLimits.parseUsage(Data(json.utf8), capturedAt: now))
        XCTAssertEqual(snapshot.windows.map(\.label), ["5-hour", "Weekly"])
        XCTAssertEqual(snapshot.plan, "Plus")
        XCTAssertEqual(snapshot.detail, "Credits: 250")
    }

    func testGeminiQuota() throws {
        let json = #"""
        {"buckets":[
          {"modelId":"gemini-2.5-flash","tokenType":"REQUESTS","remainingFraction":0.9,"resetTime":"2025-10-22T16:01:15Z"},
          {"modelId":"gemini-2.5-pro","tokenType":"REQUESTS","remainingFraction":0.25,"resetTime":"2025-10-22T16:01:15Z"},
          {"modelId":"gemini-2.5-pro","tokenType":"TOKENS","remainingFraction":0.5,"resetTime":"2025-10-22T16:01:15Z"}
        ]}
        """#
        let snapshot = try XCTUnwrap(GeminiLimits.parseQuota(Data(json.utf8), capturedAt: now, plan: "Free"))
        XCTAssertEqual(snapshot.windows.map(\.label), ["2.5 Pro", "2.5 Flash"])
        XCTAssertEqual(snapshot.windows[0].usedPercent, 75, accuracy: 0.001)
        XCTAssertEqual(GeminiLimits.parsePlan(Data(#"{"currentTier":{"id":"free-tier"},"cloudaicompanionProject":"p-123"}"#.utf8)).project, "p-123")
    }

    func testCredentialFiles() {
        let codex = CodexCredentials.parse(Data(#"{"OPENAI_API_KEY":null,"tokens":{"id_token":"a","access_token":"b","refresh_token":"c","account_id":"acc"}}"#.utf8))
        XCTAssertEqual(codex, CodexCredentials(accessToken: "b", accountID: "acc"))

        let gemini = GeminiCredentials.parse(Data(#"{"access_token":"ya29","refresh_token":"1//r","expiry_date":1761003600000,"token_type":"Bearer"}"#.utf8))
        XCTAssertEqual(gemini?.hasValidAccessToken(at: now), true)
        XCTAssertEqual(gemini?.hasValidAccessToken(at: now.addingTimeInterval(7200)), false)

        // Gemini CLI's Keychain format.
        let keychain = GeminiCredentials.parse(Data(#"{"serverName":"main-account","token":{"accessToken":"ya29.k","refreshToken":"1//k","expiresAt":1761003600000,"tokenType":"Bearer"},"updatedAt":1}"#.utf8))
        XCTAssertEqual(keychain?.accessToken, "ya29.k")
        XCTAssertEqual(keychain?.refreshToken, "1//k")
        XCTAssertEqual(keychain?.expiresAt, Date(timeIntervalSince1970: 1_761_003_600))
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

final class CredentialExpiryTests: XCTestCase {
    func testCodexTokenExpiryFromJWT() throws {
        func jwt(exp: Int) -> String {
            let payload = Data(#"{"exp":\#(exp),"sub":"user"}"#.utf8).base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
            return "eyJhbGciOiJSUzI1NiJ9.\(payload).signature"
        }
        let json = #"{"tokens":{"access_token":"\#(jwt(exp: 1_761_000_000))","account_id":"acc"}}"#
        let credentials = try XCTUnwrap(CodexCredentials.parse(Data(json.utf8)))
        XCTAssertEqual(credentials.expiresAt, Date(timeIntervalSince1970: 1_761_000_000))
        XCTAssertTrue(credentials.isExpired(at: Date(timeIntervalSince1970: 1_761_000_001)))
        XCTAssertFalse(credentials.isExpired(at: Date(timeIntervalSince1970: 1_760_999_000)))

        let opaque = try XCTUnwrap(CodexCredentials.parse(Data(#"{"tokens":{"access_token":"not-a-jwt"}}"#.utf8)))
        XCTAssertNil(opaque.expiresAt)
        XCTAssertFalse(opaque.isExpired(at: Date()))
    }

    func testErrorHint() {
        let error = KvotaError("Long explanation.", short: "Run codex to refresh login")
        XCTAssertEqual(error.short, "Run codex to refresh login")
        XCTAssertEqual(error.errorDescription, "Long explanation.")
        XCTAssertNil(KvotaError("x").short)
    }
}
