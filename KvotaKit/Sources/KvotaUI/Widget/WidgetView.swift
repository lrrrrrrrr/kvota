import KvotaCore
import SwiftUI

/// The always-visible floating widget.
struct WidgetView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.settings.widgetStyle {
            case .compact: compact
            case .detailed: detailed
            }
        }
        .background(WidgetBackground(cornerRadius: model.settings.widgetStyle == .compact ? 11 : 13))
        .fixedSize()
        .contextMenu { menu }
    }

    private var providers: [ProviderID] { model.visibleProviders }

    // MARK: Compact: one ring and number per provider

    private var compact: some View {
        HStack(spacing: 12) {
            if providers.isEmpty {
                Text("Kvota").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            ForEach(providers) { provider in
                CompactItem(state: model.state(for: provider), now: model.now)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
    }

    // MARK: Detailed: bars with reset times

    private var detailed: some View {
        VStack(alignment: .leading, spacing: 10) {
            if providers.isEmpty {
                Text("No providers enabled").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(providers) { provider in
                DetailedItem(state: model.state(for: provider), now: model.now, showCost: model.settings.showCost)
            }
        }
        .padding(11)
        .frame(width: 232, alignment: .leading)
    }

    @ViewBuilder
    private var menu: some View {
        Button(model.settings.widgetStyle == .compact ? "Show Details" : "Compact View") {
            model.settings.widgetStyle = model.settings.widgetStyle == .compact ? .detailed : .compact
        }
        Button("Make Click-Through") { model.settings.widgetClickThrough = true }
        Button(model.settings.widgetOnTop ? "Keep Behind Windows" : "Keep on Top") {
            model.settings.widgetOnTop.toggle()
        }
        Divider()
        Button("Refresh") { model.refreshNow() }
        Button("Settings…") { model.openSettings(.widget) }
        Divider()
        Button("Hide Widget") { model.setWidgetVisible(false) }
    }
}

private struct CompactItem: View {
    let state: ProviderState
    let now: Date

    var body: some View {
        let provider = state.provider
        let used = state.highestPercent(at: now)
        HStack(spacing: 6) {
            RingGauge(
                fraction: used.map { $0 / 100 },
                color: used.map { Theme.fill(for: $0, tint: provider.tint) } ?? provider.tint,
                lineWidth: 2.6
            )
            .frame(width: 17, height: 17)
            VStack(alignment: .leading, spacing: -1) {
                Text(provider.displayName)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(valueText(used))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(provider.displayName) \(valueText(used))")
    }

    private func valueText(_ used: Double?) -> String {
        if let used { return Format.percent(used) }
        if let tokens = state.usage?.today.tokens.total, tokens > 0 { return Format.tokens(tokens) }
        return "–"
    }

    private var helpText: String {
        var lines: [String] = []
        if let limits = state.limits {
            for window in limits.windows {
                var line = "\(window.label): \(Format.percent(window.usedPercent(at: now)))"
                if let resets = window.resetsAt, !window.isExpired(at: now) {
                    line += ", resets in \(Format.countdown(to: resets, from: now))"
                }
                lines.append(line)
            }
        }
        if let usage = state.usage, usage.hasActivity {
            lines.append("Today: \(Format.tokens(usage.today.tokens.total)) tokens")
        }
        return lines.isEmpty ? "\(state.provider.displayName): no data yet" : lines.joined(separator: "\n")
    }
}

private struct DetailedItem: View {
    let state: ProviderState
    let now: Date
    let showCost: Bool

    var body: some View {
        let provider = state.provider
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                ProviderDot(provider: provider, size: 6)
                Text(provider.displayName)
                    .font(.system(size: 11, weight: .semibold))
                if let plan = state.limits?.plan {
                    PlanBadge(text: plan)
                }
                Spacer(minLength: 4)
                if let usage = state.usage, usage.today.tokens.total > 0 {
                    Text(todayText(usage.today))
                        .font(.system(size: 9))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            if let limits = state.limits, !limits.windows.isEmpty {
                ForEach(limits.windows.prefix(2)) { window in
                    LimitRow(window: window, tint: provider.tint, now: now, dense: true)
                }
            } else {
                Text(state.usage?.hasActivity == true ? "No limit data yet" : "No activity yet")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func todayText(_ totals: UsageTotals) -> String {
        let tokens = "\(Format.tokens(totals.tokens.total)) today"
        guard showCost, totals.cost > 0 else { return tokens }
        return "\(tokens) · ≈\(Format.cost(totals.cost))"
    }
}
