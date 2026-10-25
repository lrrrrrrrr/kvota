import Foundation
import KvotaCore

/// Realistic fixed data for previews, snapshot tests and App Store screenshots.
enum SampleData {
    static func model(now: Date = Date(timeIntervalSince1970: 1_792_929_600), style: WidgetStyle = .compact) -> AppModel {
        var settings = AppSettings()
        settings.widgetStyle = style
        settings.hasLaunchedBefore = true
        return AppModel(preview: settings, states: states(now: now), now: now)
    }

    static func states(now: Date) -> [ProviderState] {
        func hours(_ h: Double) -> Date { now.addingTimeInterval(h * 3600) }

        var claude = ProviderState(provider: .claude)
        claude.access = .available
        claude.bridgeInstalled = true
        claude.localLimits = LimitsSnapshot(
            provider: .claude,
            windows: [
                LimitWindow(id: "session", label: "5-hour", usedPercent: 62, resetsAt: hours(2.3), duration: 5 * 3600),
                LimitWindow(id: "weekly", label: "Weekly", usedPercent: 38, resetsAt: hours(76), duration: 7 * 86_400),
            ],
            plan: "Max",
            capturedAt: now.addingTimeInterval(-240),
            source: .statusLine
        )
        claude.usage = usage(.claude, now: now, today: 18_400_000, cost: 21.7, week: [9, 14, 3, 11, 22, 16, 18.4], models: [
            ("claude-opus-4-5", 15_200_000, 19.9), ("claude-haiku-4-5", 3_200_000, 1.8),
        ])

        var codex = ProviderState(provider: .codex)
        codex.access = .available
        codex.localLimits = LimitsSnapshot(
            provider: .codex,
            windows: [
                LimitWindow(id: "session", label: "5-hour", usedPercent: 81, resetsAt: hours(1.2), duration: 5 * 3600),
                LimitWindow(id: "weekly", label: "Weekly", usedPercent: 47, resetsAt: hours(101), duration: 7 * 86_400),
            ],
            plan: "Plus",
            capturedAt: now.addingTimeInterval(-90),
            source: .sessionLog
        )
        codex.usage = usage(.codex, now: now, today: 6_900_000, cost: 5.4, week: [4, 0, 6, 8, 2, 5, 6.9], models: [
            ("gpt-5.1-codex", 6_900_000, 5.4),
        ])

        var gemini = ProviderState(provider: .gemini)
        gemini.access = .available
        gemini.liveLimits = LimitsSnapshot(
            provider: .gemini,
            windows: [
                LimitWindow(id: "model-gemini-2.5-pro", label: "2.5 Pro", usedPercent: 24, resetsAt: hours(13), duration: 86_400),
                LimitWindow(id: "model-gemini-2.5-flash", label: "2.5 Flash", usedPercent: 6, resetsAt: hours(13), duration: 86_400),
            ],
            plan: "Free",
            capturedAt: now.addingTimeInterval(-120),
            source: .live
        )
        gemini.usage = usage(.gemini, now: now, today: 1_300_000, cost: 1.1, week: [0, 2, 1, 0, 0, 3, 1.3], models: [
            ("gemini-2.5-pro", 1_300_000, 1.1),
        ])

        return [claude, codex, gemini]
    }

    private static func usage(
        _ provider: ProviderID, now: Date, today: Int64, cost: Double, week: [Double],
        models: [(String, Int64, Double)]
    ) -> ProviderUsageSummary {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        let daily = week.enumerated().map { index, millions in
            DayUsage(
                day: calendar.date(byAdding: .day, value: index - 6, to: start) ?? start,
                totals: UsageTotals(tokens: TokenCounts(input: Int64(millions * 1_000_000)), cost: millions * cost / max(1, Double(today) / 1_000_000), requests: Int(millions * 40))
            )
        }
        let todayTotals = UsageTotals(tokens: TokenCounts(input: today / 10, output: today / 20, cacheRead: today - today / 10 - today / 20), cost: cost, requests: 180)
        let weekTokens = Int64(week.reduce(0, +) * 1_000_000)
        return ProviderUsageSummary(
            provider: provider,
            today: todayTotals,
            last5Hours: todayTotals,
            last7Days: UsageTotals(tokens: TokenCounts(input: weekTokens), cost: cost * 4.6, requests: 1100),
            thisMonth: UsageTotals(tokens: TokenCounts(input: weekTokens * 3), cost: cost * 14, requests: 4100),
            daily: daily,
            models: models.map { ModelUsage(model: $0.0, totals: UsageTotals(tokens: TokenCounts(input: $0.1), cost: $0.2, requests: 120)) },
            lastActivity: now.addingTimeInterval(-90),
            filesTracked: 42
        )
    }
}
