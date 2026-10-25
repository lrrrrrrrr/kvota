import Foundation

/// Where a limits reading came from.
public enum LimitSource: String, Sendable, Codable, Equatable {
    /// Written by the CLI into its own session logs (Codex).
    case sessionLog
    /// Captured from Claude Code's status line data by Kvota's bridge script.
    case statusLine
    /// Fetched from the provider's usage endpoint with the CLI's existing login.
    case live

    public var displayName: String {
        switch self {
        case .sessionLog: "session log"
        case .statusLine: "status line"
        case .live: "live"
        }
    }
}

/// One usage window, for example the 5-hour session limit or the weekly limit.
public struct LimitWindow: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var label: String
    /// Share of the window already used, 0–100. Can exceed 100 for spend limits.
    public var usedPercent: Double
    public var resetsAt: Date?
    public var duration: TimeInterval?

    public init(id: String, label: String, usedPercent: Double, resetsAt: Date? = nil, duration: TimeInterval? = nil) {
        self.id = id
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.duration = duration
    }

    /// A window whose reset time has passed starts again from zero.
    public func isExpired(at now: Date) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt <= now
    }

    public func usedPercent(at now: Date) -> Double {
        isExpired(at: now) ? 0 : max(0, usedPercent)
    }

    public func remainingPercent(at now: Date) -> Double {
        max(0, 100 - usedPercent(at: now))
    }
}

/// A provider's limit windows at one point in time.
public struct LimitsSnapshot: Sendable, Equatable, Codable {
    public var provider: ProviderID
    public var windows: [LimitWindow]
    public var plan: String?
    public var capturedAt: Date
    public var source: LimitSource
    /// Extra one-line context, such as a credit balance.
    public var detail: String?

    public init(
        provider: ProviderID,
        windows: [LimitWindow],
        plan: String? = nil,
        capturedAt: Date,
        source: LimitSource,
        detail: String? = nil
    ) {
        self.provider = provider
        self.windows = windows
        self.plan = plan
        self.capturedAt = capturedAt
        self.source = source
        self.detail = detail
    }

    /// The window closest to running out.
    public func mostConstrained(at now: Date) -> LimitWindow? {
        windows.max { $0.usedPercent(at: now) < $1.usedPercent(at: now) }
    }

    public func highestUsedPercent(at now: Date) -> Double? {
        mostConstrained(at: now)?.usedPercent(at: now)
    }

    /// Picks the newer of two readings. Live readings win ties.
    public static func newest(_ a: LimitsSnapshot?, _ b: LimitsSnapshot?) -> LimitsSnapshot? {
        guard let a else { return b }
        guard let b else { return a }
        if abs(a.capturedAt.timeIntervalSince(b.capturedAt)) < 1 {
            return a.source == .live ? a : b
        }
        return a.capturedAt > b.capturedAt ? a : b
    }
}

/// Fetches limits straight from a provider. Only the direct-download build ships an
/// implementation; the App Store build reads local files only.
public protocol LiveLimitsProvider: AnyObject, Sendable {
    var supportedProviders: [ProviderID] { get }
    /// - Parameter home: the provider's home folder, for example `~/.codex`.
    func fetchLimits(for provider: ProviderID, home: URL) async throws -> LimitsSnapshot
}

public struct KvotaError: LocalizedError, Equatable, Sendable {
    public let message: String
    /// A few words for tight spaces, such as "Run codex to sign in again".
    public let short: String?

    public init(_ message: String, short: String? = nil) {
        self.message = message
        self.short = short
    }

    public var errorDescription: String? { message }
}
