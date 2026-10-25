import Foundation

/// API list prices for one model, in USD per token.
public struct ModelPrice: Sendable, Equatable {
    public let input: Double
    public let output: Double
    public let cacheRead: Double
    public let cacheWrite: Double

    public init(input: Double, output: Double, cacheRead: Double, cacheWrite: Double) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    public func cost(of counts: TokenCounts) -> Double {
        Double(counts.input) * input
            + Double(counts.output) * output
            + Double(counts.cacheRead) * (cacheRead > 0 ? cacheRead : input)
            + Double(counts.cacheWrite) * (cacheWrite > 0 ? cacheWrite : input)
    }
}

/// Estimates what usage would cost at public API prices.
///
/// Subscription plans are not billed per token, so for most people this is the
/// "API-equivalent value" of their usage rather than a bill.
public enum Pricing {
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: ModelPrice?] = [:]

    public static func price(for model: String) -> ModelPrice? {
        cacheLock.lock()
        if let hit = cache[model] {
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()
        let resolved = resolve(model)
        cacheLock.lock()
        cache[model] = .some(resolved)
        cacheLock.unlock()
        return resolved
    }

    public static func cost(_ counts: TokenCounts, model: String) -> Double? {
        price(for: model)?.cost(of: counts)
    }

    static func normalize(_ model: String) -> String {
        var name = model.lowercased().trimmingCharacters(in: .whitespaces)
        for prefix in ["anthropic/", "openai/", "google/", "models/", "gemini/", "us.anthropic.", "anthropic."] where name.hasPrefix(prefix) {
            name.removeFirst(prefix.count)
        }
        // "claude-sonnet-4-5[1m]" -> "claude-sonnet-4-5"
        if let bracket = name.firstIndex(of: "[") {
            name = String(name[..<bracket])
        }
        return name
    }

    static func resolve(_ model: String) -> ModelPrice? {
        let name = normalize(model)
        if let exact = table[name] { return exact }

        // Drop a trailing date: claude-haiku-4-5-20251001, gpt-5-2025-08-07.
        let undated = name.replacingOccurrences(
            of: #"-(\d{8}|\d{4}-\d{2}-\d{2})$"#, with: "", options: .regularExpression
        )
        if let exact = table[undated] { return exact }

        // Longest known model name that prefixes this one: gpt-5.1-codex-max-high -> gpt-5.1-codex-max.
        var best: (key: String, price: ModelPrice)?
        for (key, price) in table where undated.hasPrefix(key) {
            let boundary = undated.index(undated.startIndex, offsetBy: key.count)
            let next = boundary < undated.endIndex ? undated[boundary] : "-"
            guard next == "-" || next == "@" || next == ":" else { continue }
            if key.count > (best?.key.count ?? 0) { best = (key, price) }
        }
        if let best { return best.price }

        return familyFallback(undated)
    }

    /// Unknown versions get the price of a known model from the same family.
    static func familyFallback(_ name: String) -> ModelPrice? {
        func pick(_ key: String) -> ModelPrice? { table[key] }
        if name.contains("claude") || name.contains("opus") || name.contains("sonnet") || name.contains("haiku") {
            if name.contains("opus") { return pick("claude-opus-4-5") }
            if name.contains("sonnet") { return pick("claude-sonnet-4-5") }
            if name.contains("haiku") { return pick("claude-haiku-4-5") }
            return nil
        }
        if name.hasPrefix("gemini") {
            let isLegacy = name.contains("2.5")
            if name.contains("flash-lite") { return pick(isLegacy ? "gemini-2.5-flash-lite" : "gemini-3.1-flash-lite") }
            if name.contains("flash") { return pick(isLegacy ? "gemini-2.5-flash" : "gemini-3-flash-preview") }
            if name.contains("pro") { return pick(isLegacy ? "gemini-2.5-pro" : "gemini-3.1-pro-preview") }
            return nil
        }
        if name.contains("codex") {
            if name.contains("mini") { return pick("gpt-5.1-codex-mini") }
            return pick("gpt-5-codex")
        }
        if name.hasPrefix("gpt-5") { return pick("gpt-5") }
        return nil
    }
}
