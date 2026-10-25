import Foundation
@testable import KvotaCore

/// Builds throwaway provider home folders with log files for tests.
final class TempHome {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kvota-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func write(_ relativePath: String, _ contents: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func append(_ relativePath: String, _ contents: String) throws {
        let url = root.appendingPathComponent(relativePath)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(contents.utf8))
        try handle.close()
    }

    /// Bumps the modification time so the engine notices a change made within the same second.
    func touch(_ relativePath: String, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: root.appendingPathComponent(relativePath).path)
    }
}

enum Lines {
    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    static func claude(id: String, request: String = "req_1", at date: Date, model: String = "claude-sonnet-4-5-20250929",
                       input: Int = 100, output: Int = 50, cacheRead: Int = 1000, cacheWrite: Int = 200) -> String {
        #"{"parentUuid":"x","type":"assistant","timestamp":"\#(iso(date))","requestId":"\#(request)","message":{"id":"\#(id)","model":"\#(model)","role":"assistant","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_read_input_tokens":\#(cacheRead),"cache_creation_input_tokens":\#(cacheWrite)}}}"#
    }

    static func claudeUser(at date: Date) -> String {
        #"{"type":"user","timestamp":"\#(iso(date))","message":{"role":"user","content":"hello \"usage\" please"}}"#
    }

    static func codexTurnContext(model: String, at date: Date) -> String {
        #"{"timestamp":"\#(iso(date))","type":"turn_context","payload":{"cwd":"/tmp","model":"\#(model)","approval_policy":"on-request"}}"#
    }

    static func codexTokenCount(at date: Date, totalInput: Int, totalCached: Int, totalOutput: Int,
                                lastInput: Int, lastCached: Int, lastOutput: Int, reasoning: Int = 0,
                                primaryUsed: Double = 12.5, resetsAt: Date? = nil) -> String {
        let total = totalInput + totalOutput
        let last = lastInput + lastOutput
        let reset = Int((resetsAt ?? date.addingTimeInterval(3600)).timeIntervalSince1970)
        let weeklyReset = Int(date.addingTimeInterval(5 * 86_400).timeIntervalSince1970)
        return #"{"timestamp":"\#(iso(date))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(totalInput),"cached_input_tokens":\#(totalCached),"output_tokens":\#(totalOutput),"reasoning_output_tokens":\#(reasoning),"total_tokens":\#(total)},"last_token_usage":{"input_tokens":\#(lastInput),"cached_input_tokens":\#(lastCached),"output_tokens":\#(lastOutput),"reasoning_output_tokens":\#(reasoning),"total_tokens":\#(last)},"model_context_window":272000},"rate_limits":{"limit_id":"codex","primary":{"used_percent":\#(primaryUsed),"window_minutes":300,"resets_at":\#(reset)},"secondary":{"used_percent":40.0,"window_minutes":10080,"resets_at":\#(weeklyReset)},"credits":null,"plan_type":"plus"}}}"#
    }

    static func codexRateLimitsOnly(at date: Date, used: Double, resetsInSeconds: Int) -> String {
        #"{"timestamp":"\#(iso(date))","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":\#(used),"window_minutes":300,"resets_in_seconds":\#(resetsInSeconds)},"secondary":null}}}"#
    }

    static func geminiMessage(id: String, at date: Date, model: String = "gemini-2.5-pro",
                              input: Int = 1000, output: Int = 200, cached: Int = 400, thoughts: Int = 50, tool: Int = 0) -> String {
        #"{"id":"\#(id)","timestamp":"\#(iso(date))","type":"gemini","content":"done","model":"\#(model)","tokens":{"input":\#(input),"output":\#(output),"cached":\#(cached),"thoughts":\#(thoughts),"tool":\#(tool),"total":\#(input + output + thoughts + tool)}}"#
    }
}
