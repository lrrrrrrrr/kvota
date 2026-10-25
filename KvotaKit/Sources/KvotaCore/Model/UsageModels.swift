import Foundation

/// Token counts for one or more model requests.
///
/// `input` is the non-cached prompt. `output` includes reasoning tokens;
/// `reasoning` is kept separately for display only.
public struct TokenCounts: Sendable, Equatable, Hashable, Codable {
    public var input: Int64
    public var output: Int64
    public var cacheRead: Int64
    public var cacheWrite: Int64
    public var reasoning: Int64

    public init(input: Int64 = 0, output: Int64 = 0, cacheRead: Int64 = 0, cacheWrite: Int64 = 0, reasoning: Int64 = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.reasoning = reasoning
    }

    /// Everything the model processed or produced.
    public var total: Int64 { input + output + cacheRead + cacheWrite }

    public var isZero: Bool { total == 0 && reasoning == 0 }

    public static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        TokenCounts(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
            reasoning: lhs.reasoning + rhs.reasoning
        )
    }

    public static func - (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        TokenCounts(
            input: lhs.input - rhs.input,
            output: lhs.output - rhs.output,
            cacheRead: lhs.cacheRead - rhs.cacheRead,
            cacheWrite: lhs.cacheWrite - rhs.cacheWrite,
            reasoning: lhs.reasoning - rhs.reasoning
        )
    }

    public static func += (lhs: inout TokenCounts, rhs: TokenCounts) { lhs = lhs + rhs }
    public static func -= (lhs: inout TokenCounts, rhs: TokenCounts) { lhs = lhs - rhs }
}

/// Totals over a period: tokens, estimated API cost and number of requests.
public struct UsageTotals: Sendable, Equatable {
    public var tokens: TokenCounts
    /// Estimated cost at public API prices, in USD. Subscription users do not pay this;
    /// it shows how much value the subscription delivered.
    public var cost: Double
    public var requests: Int
    /// Tokens from models without a known price (not included in `cost`).
    public var unpricedTokens: Int64

    public init(tokens: TokenCounts = TokenCounts(), cost: Double = 0, requests: Int = 0, unpricedTokens: Int64 = 0) {
        self.tokens = tokens
        self.cost = cost
        self.requests = requests
        self.unpricedTokens = unpricedTokens
    }

    public var isEmpty: Bool { requests == 0 && tokens.isZero }

    public mutating func add(_ counts: TokenCounts, requests: Int, cost: Double?) {
        tokens += counts
        self.requests += requests
        if let cost {
            self.cost += cost
        } else {
            unpricedTokens += counts.total
        }
    }
}

public struct DayUsage: Sendable, Equatable, Identifiable {
    public var day: Date
    public var totals: UsageTotals
    public var id: Date { day }

    public init(day: Date, totals: UsageTotals) {
        self.day = day
        self.totals = totals
    }
}

public struct ModelUsage: Sendable, Equatable, Identifiable {
    public var model: String
    public var totals: UsageTotals
    public var id: String { model }

    public init(model: String, totals: UsageTotals) {
        self.model = model
        self.totals = totals
    }
}

/// Everything Kvota shows about one provider's token usage.
public struct ProviderUsageSummary: Sendable, Equatable {
    public var provider: ProviderID
    public var today: UsageTotals
    public var last5Hours: UsageTotals
    public var last7Days: UsageTotals
    public var thisMonth: UsageTotals
    /// The last seven days including today, oldest first.
    public var daily: [DayUsage]
    /// Per-model totals for the last seven days, largest first.
    public var models: [ModelUsage]
    public var lastActivity: Date?
    public var filesTracked: Int

    public init(
        provider: ProviderID,
        today: UsageTotals = UsageTotals(),
        last5Hours: UsageTotals = UsageTotals(),
        last7Days: UsageTotals = UsageTotals(),
        thisMonth: UsageTotals = UsageTotals(),
        daily: [DayUsage] = [],
        models: [ModelUsage] = [],
        lastActivity: Date? = nil,
        filesTracked: Int = 0
    ) {
        self.provider = provider
        self.today = today
        self.last5Hours = last5Hours
        self.last7Days = last7Days
        self.thisMonth = thisMonth
        self.daily = daily
        self.models = models
        self.lastActivity = lastActivity
        self.filesTracked = filesTracked
    }

    public var hasActivity: Bool { lastActivity != nil }
}
