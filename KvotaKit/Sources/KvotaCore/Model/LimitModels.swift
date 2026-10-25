import Foundation

/// Where a limits reading came from.
public enum LimitSource: String, Sendable, Codable, Equatable {
    /// Written by the CLI into its own session logs (Codex).
    case sessionLog
    /// Captured from Claude Code's status line data by Kvota's bridge script.
    case statusLine

    public var displayName: String {
        switch self {
        case .sessionLog: "session log"
        case .statusLine: "status line"
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

    /// The window closest to running out. Windows that have reset since the reading are
    /// skipped: what was used in them since is unknown until the next reading.
    public func mostConstrained(at now: Date) -> LimitWindow? {
        windows
            .filter { !$0.isExpired(at: now) }
            .max { $0.usedPercent(at: now) < $1.usedPercent(at: now) }
    }

    public func highestUsedPercent(at now: Date) -> Double? {
        mostConstrained(at: now)?.usedPercent(at: now)
    }

    /// Picks the newer of two readings.
    public static func newest(_ a: LimitsSnapshot?, _ b: LimitsSnapshot?) -> LimitsSnapshot? {
        guard let a else { return b }
        guard let b else { return a }
        return a.capturedAt >= b.capturedAt ? a : b
    }
}

public struct KvotaError: LocalizedError, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}
