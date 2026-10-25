import XCTest
import libzstd
@testable import KvotaCore

final class EngineTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 2026-10-25 12:00 UTC
    private let now = Date(timeIntervalSince1970: 1_792_929_600)

    func testClaudeIncrementalScanAndDeduplication() throws {
        let home = try TempHome()
        let file = "projects/-Users-me-app/session-a.jsonl"
        let t1 = now.addingTimeInterval(-3600)
        try home.write(file, [
            Lines.claude(id: "msg_1", at: t1, output: 10),
            Lines.claude(id: "msg_1", at: t1, output: 50), // streamed again, more complete
            Lines.claudeUser(at: t1),
        ].joined(separator: "\n") + "\n")

        let engine = UsageEngine()
        XCTAssertTrue(engine.scan(.claude, home: home.root, now: now))
        var summary = engine.summary(.claude, now: now, calendar: utc)
        XCTAssertEqual(summary.today.requests, 1)
        XCTAssertEqual(summary.today.tokens.output, 50)
        XCTAssertEqual(summary.today.tokens.total, 100 + 50 + 1000 + 200)
        XCTAssertGreaterThan(summary.today.cost, 0)

        // Nothing changed: no work, same result.
        XCTAssertFalse(engine.scan(.claude, home: home.root, now: now))

        // Append a new reply plus a half-written line.
        try home.append(file, Lines.claude(id: "msg_2", at: now.addingTimeInterval(-60)) + "\n{\"type\":\"assist")
        try home.touch(file, now.addingTimeInterval(1))
        XCTAssertTrue(engine.scan(.claude, home: home.root, now: now))
        summary = engine.summary(.claude, now: now, calendar: utc)
        XCTAssertEqual(summary.today.requests, 2)

        // A resumed session copies msg_1 into a new file: not counted twice.
        try home.write("projects/-Users-me-app/session-b.jsonl", Lines.claude(id: "msg_1", at: t1, output: 50) + "\n")
        try home.touch("projects/-Users-me-app/session-b.jsonl", now.addingTimeInterval(2))
        XCTAssertTrue(engine.scan(.claude, home: home.root, now: now))
        summary = engine.summary(.claude, now: now, calendar: utc)
        XCTAssertEqual(summary.today.requests, 2)
        XCTAssertEqual(summary.models.first?.model, "claude-sonnet-4-5-20250929")
        XCTAssertEqual(summary.daily.count, 7)
        XCTAssertEqual(summary.daily.last?.totals.requests, 2)
        XCTAssertEqual(summary.lastActivity, now.addingTimeInterval(-60))
    }

    func testWindowsAndRetention() throws {
        let home = try TempHome()
        try home.write("projects/p/s.jsonl", [
            Lines.claude(id: "today", at: now.addingTimeInterval(-2 * 3600)),
            Lines.claude(id: "yesterday", at: now.addingTimeInterval(-26 * 3600)),
            Lines.claude(id: "lastweek", at: now.addingTimeInterval(-5 * 86_400)),
            Lines.claude(id: "ancient", at: now.addingTimeInterval(-90 * 86_400)),
        ].joined(separator: "\n") + "\n")
        let engine = UsageEngine()
        engine.scan(.claude, home: home.root, now: now)
        let summary = engine.summary(.claude, now: now, calendar: utc)
        XCTAssertEqual(summary.last5Hours.requests, 1)
        XCTAssertEqual(summary.today.requests, 1)
        XCTAssertEqual(summary.last7Days.requests, 3)
        XCTAssertEqual(summary.thisMonth.requests, 3)
        XCTAssertEqual(summary.daily.map(\.totals.requests), [0, 1, 0, 0, 0, 1, 1])
    }

    func testCodexUsageAndLimitsFromRollouts() throws {
        let home = try TempHome()
        let t = now.addingTimeInterval(-1800)
        let path = "sessions/2026/10/25/rollout-2026-10-25T11-30-00-abc.jsonl"
        try home.write(path, [
            #"{"timestamp":"\#(Lines.iso(t))","type":"session_meta","payload":{"id":"abc","cwd":"/tmp","cli_version":"0.50.0"}}"#,
            Lines.codexTurnContext(model: "gpt-5.1-codex", at: t),
            Lines.codexTokenCount(at: t.addingTimeInterval(10), totalInput: 5000, totalCached: 3000, totalOutput: 400,
                                  lastInput: 5000, lastCached: 3000, lastOutput: 400, reasoning: 100, primaryUsed: 10),
            // Same totals again (rate-limit refresh only): must not double count.
            Lines.codexTokenCount(at: t.addingTimeInterval(20), totalInput: 5000, totalCached: 3000, totalOutput: 400,
                                  lastInput: 5000, lastCached: 3000, lastOutput: 400, reasoning: 100, primaryUsed: 11),
            Lines.codexTokenCount(at: t.addingTimeInterval(60), totalInput: 9000, totalCached: 6000, totalOutput: 900,
                                  lastInput: 4000, lastCached: 3000, lastOutput: 500, primaryUsed: 14),
        ].joined(separator: "\n") + "\n")

        let engine = UsageEngine()
        engine.scan(.codex, home: home.root, now: now)
        let summary = engine.summary(.codex, now: now, calendar: utc)
        XCTAssertEqual(summary.today.requests, 2)
        XCTAssertEqual(summary.today.tokens.input, 2000 + 1000)
        XCTAssertEqual(summary.today.tokens.cacheRead, 3000 + 3000)
        XCTAssertEqual(summary.today.tokens.output, 900)
        XCTAssertEqual(summary.models.first?.model, "gpt-5.1-codex")

        let limits = try XCTUnwrap(engine.limitsFromLogs(.codex))
        XCTAssertEqual(limits.windows.first?.usedPercent, 14)
        XCTAssertEqual(limits.plan, "Plus")
        XCTAssertEqual(limits.source, .sessionLog)
    }

    func testCodexCompressedRollout() throws {
        let home = try TempHome()
        let t = now.addingTimeInterval(-9 * 86_400)
        let text = [
            Lines.codexTurnContext(model: "gpt-5-codex", at: t),
            Lines.codexTokenCount(at: t, totalInput: 1000, totalCached: 0, totalOutput: 100,
                                  lastInput: 1000, lastCached: 0, lastOutput: 100),
        ].joined(separator: "\n") + "\n"
        let compressed = try Self.zstdCompress(Data(text.utf8))
        let url = home.root.appendingPathComponent("sessions/2026/10/16/rollout-2026-10-16T12-00-00-old.jsonl.zst")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try compressed.write(to: url)

        let engine = UsageEngine()
        engine.scan(.codex, home: home.root, now: now)
        let summary = engine.summary(.codex, now: now, calendar: utc)
        XCTAssertEqual(summary.thisMonth.requests, 1)
        XCTAssertEqual(summary.thisMonth.tokens.input, 1000)
        XCTAssertEqual(summary.today.requests, 0)
    }

    func testGeminiJSONLAndLegacyDocuments() throws {
        let home = try TempHome()
        let t = now.addingTimeInterval(-600)
        try home.write("tmp/abc123/chats/session-2026-10-25T11-50-x.jsonl", [
            #"{"sessionId":"s1","projectHash":"abc123","startTime":"\#(Lines.iso(t))","lastUpdated":"\#(Lines.iso(t))"}"#,
            #"{"id":"u1","timestamp":"\#(Lines.iso(t))","type":"user","content":"hi"}"#,
            Lines.geminiMessage(id: "g1", at: t),
            Lines.geminiMessage(id: "g1", at: t), // record rewritten with tool calls
            #"{"$set":{"lastUpdated":"\#(Lines.iso(t))"}}"#,
        ].joined(separator: "\n") + "\n")
        try home.write("tmp/def456/chats/session-2025-old.json", #"""
        {"sessionId":"s2","projectHash":"def456","messages":[
          \#(Lines.geminiMessage(id: "g2", at: t, model: "gemini-2.5-flash", input: 300, output: 30, cached: 0, thoughts: 0))
        ]}
        """#)
        try home.write("tmp/def456/logs.json", #"[{"tokens":1}]"#)

        let engine = UsageEngine()
        engine.scan(.gemini, home: home.root, now: now)
        let summary = engine.summary(.gemini, now: now, calendar: utc)
        XCTAssertEqual(summary.today.requests, 2)
        // g1: input 1000 - cached 400 = 600; output 200 + thoughts 50. g2: 300 / 30.
        XCTAssertEqual(summary.today.tokens.input, 600 + 300)
        XCTAssertEqual(summary.today.tokens.cacheRead, 400)
        XCTAssertEqual(summary.today.tokens.output, 250 + 30)
        XCTAssertEqual(Set(summary.models.map(\.model)), ["gemini-2.5-pro", "gemini-2.5-flash"])
    }

    func testRewrittenFileIsReadAgain() throws {
        let home = try TempHome()
        let file = "projects/p/s.jsonl"
        try home.write(file, [
            Lines.claude(id: "a", at: now.addingTimeInterval(-100)),
            Lines.claude(id: "b", at: now.addingTimeInterval(-90)),
        ].joined(separator: "\n") + "\n")
        let engine = UsageEngine()
        engine.scan(.claude, home: home.root, now: now)
        XCTAssertEqual(engine.summary(.claude, now: now, calendar: utc).today.requests, 2)

        // Shorter file: a rewrite, not an append.
        try home.write(file, Lines.claude(id: "c", at: now.addingTimeInterval(-80)) + "\n")
        try home.touch(file, now.addingTimeInterval(5))
        engine.scan(.claude, home: home.root, now: now)
        XCTAssertEqual(engine.summary(.claude, now: now, calendar: utc).today.requests, 1)

        try FileManager.default.removeItem(at: home.root.appendingPathComponent(file))
        XCTAssertTrue(engine.scan(.claude, home: home.root, now: now))
        XCTAssertEqual(engine.summary(.claude, now: now, calendar: utc).today.requests, 0)
    }

    func testMissingFoldersAreHarmless() throws {
        let home = try TempHome()
        let engine = UsageEngine()
        for provider in ProviderID.allCases {
            XCTAssertFalse(engine.scan(provider, home: home.root.appendingPathComponent("nope"), now: now))
            XCTAssertFalse(engine.summary(provider, now: now, calendar: utc).hasActivity)
        }
    }

    static func zstdCompress(_ data: Data) throws -> Data {
        let bound = ZSTD_compressBound(data.count)
        var output = Data(count: bound)
        let written = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                ZSTD_compress(out.baseAddress, bound, input.baseAddress, input.count, 3)
            }
        }
        guard ZSTD_isError(written) == 0 else { throw KvotaError("compression failed") }
        return output.prefix(written)
    }
}

final class StatusLineBridgeTests: XCTestCase {
    func testBridgeSavesLimitsAndPrintsSummary() throws {
        guard FileManager.default.isExecutableFile(atPath: "/bin/sh") else { throw XCTSkip("no /bin/sh") }
        let home = try TempHome()
        let script = try home.write("kvota/\(StatusLineBridgeScript.fileName)", StatusLineBridgeScript.source)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let input = #"{"session_id":"s","model":{"id":"claude-opus-4-5","display_name":"Opus 4.5"},"context_window":{"used_percentage":null},"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1761003600},"seven_day":{"used_percentage":41.2,"resets_at":1761400000}}}"#
        let output = try run(script, input: input)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "Opus 4.5 · 5h 23% · 7d 41%")

        let saved = try Data(contentsOf: home.root.appendingPathComponent("kvota/rate_limits.json"))
        let snapshot = try XCTUnwrap(ClaudeLimits.parseStatusLine(saved, capturedAt: Date()))
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [23.5, 41.2])

        // With a previous command, its output is shown instead.
        try home.write("kvota/\(StatusLineBridgeScript.previousCommandFileName)", "echo custom-line")
        XCTAssertEqual(try run(script, input: input).trimmingCharacters(in: .whitespacesAndNewlines), "custom-line")
    }

    private func run(_ script: URL, input: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
