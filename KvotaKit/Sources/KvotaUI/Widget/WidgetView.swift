import KvotaCore
import SwiftUI

/// The always-visible floating widget. Click it to expand into the full view with
/// every detail; click the header (or the chevron) to collapse it again.
struct WidgetView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.widgetExpanded {
                expanded
            } else {
                switch model.settings.widgetStyle {
                case .compact: compact
                case .detailed: detailed
                }
            }
        }
        .background(WidgetBackground(cornerRadius: model.widgetExpanded ? 14 : (model.settings.widgetStyle == .compact ? 11 : 13)))
        .fixedSize()
        .contextMenu { menu }
    }

    private var providers: [ProviderID] { model.visibleProviders }

    // MARK: Compact: one ring and what's left per provider

    private var compact: some View {
        HStack(spacing: 14) {
            if providers.isEmpty {
                Text("Kvota").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            ForEach(providers) { provider in
                CompactItem(state: model.state(for: provider), now: model.now, showRemaining: model.settings.showRemaining)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { expand() }
        .help("Click for details")
    }

    // MARK: Detailed: bars with reset times

    private var detailed: some View {
        VStack(alignment: .leading, spacing: 10) {
            if providers.isEmpty {
                Text("No providers enabled").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(providers) { provider in
                DetailedItem(
                    state: model.state(for: provider),
                    now: model.now,
                    showCost: model.settings.showCost,
                    showRemaining: model.settings.showRemaining
                )
            }
        }
        .padding(11)
        .frame(width: 250, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { expand() }
        .help("Click for details")
    }

    // MARK: Expanded: everything the menu bar window shows

    private var expanded: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Kvota")
                    .font(.system(size: 12, weight: .semibold))
                if let refreshed = model.lastRefresh {
                    Text("updated \(Format.ago(refreshed, now: model.now))")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                IconButton(symbol: "arrow.clockwise", help: "Refresh now") { model.refreshNow() }
                IconButton(symbol: "gearshape", help: "Settings") { model.openSettings(.providers) }
                IconButton(symbol: "chevron.up", help: "Collapse") { collapse() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .onTapGesture { collapse() }

            if providers.isEmpty {
                Text("All providers are hidden. Turn one on in Settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(16)
            } else {
                VStack(spacing: 8) {
                    ForEach(providers) { provider in
                        ProviderCard(state: model.state(for: provider))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .frame(width: 330)
    }

    private func expand() {
        model.widgetExpanded = true
        model.menuOpened()
    }

    private func collapse() {
        model.widgetExpanded = false
    }

    @ViewBuilder
    private var menu: some View {
        Button(model.widgetExpanded ? "Collapse" : "Show All Details") {
            model.widgetExpanded.toggle()
        }
        Button(model.settings.widgetStyle == .compact ? "Use Detailed Style" : "Use Compact Style") {
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
    let showRemaining: Bool

    var body: some View {
        let provider = state.provider
        let window = state.limits?.mostConstrained(at: now)
        let used = window?.usedPercent(at: now)
        let color = used.map { Theme.fill(for: $0, tint: provider.tint) } ?? provider.tint
        HStack(spacing: 7) {
            RingGauge(
                fraction: used.map { (showRemaining ? max(0, 100 - $0) : $0) / 100 },
                color: color,
                lineWidth: 3
            )
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(primaryText(used))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(used == nil ? Color.secondary : Color.primary)
                Text(secondaryText(window))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .lineLimit(1)
            .fixedSize()
        }
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(primaryText(used)), \(secondaryText(window))")
    }

    private var title: String {
        if let plan = state.limits?.plan { return "\(state.provider.displayName) · \(plan)" }
        return state.provider.displayName
    }

    private func primaryText(_ used: Double?) -> String {
        guard let used else {
            return state.liveError != nil ? "Not connected" : "No limits yet"
        }
        return showRemaining ? "\(Format.percent(max(0, 100 - used))) left" : "\(Format.percent(used)) used"
    }

    private func secondaryText(_ window: LimitWindow?) -> String {
        if let window {
            if let resets = window.resetsAt, !window.isExpired(at: now) {
                return "\(window.label) · resets \(Format.countdown(to: resets, from: now))"
            }
            return window.label
        }
        if state.liveError != nil {
            return state.liveErrorHint ?? "click for details"
        }
        if state.provider == .claude, state.bridgeInstalled {
            return ClaudeBridgeStatus.short(for: state.bridgeLastRun)
        }
        return "click to set up"
    }

    private var helpText: String {
        var lines: [String] = []
        if let limits = state.limits {
            for window in limits.windows {
                var line = "\(window.label): \(Format.percent(window.remainingPercent(at: now))) left"
                if let resets = window.resetsAt, !window.isExpired(at: now) {
                    line += ", resets in \(Format.countdown(to: resets, from: now))"
                }
                lines.append(line)
            }
            if let detail = limits.detail { lines.append(detail) }
        }
        if let error = state.liveError { lines.append(error) }
        if let usage = state.usage, usage.hasActivity {
            lines.append("Today: \(Format.tokens(usage.today.tokens.total)) tokens")
        }
        lines.append("Click for details")
        return lines.joined(separator: "\n")
    }
}

private struct DetailedItem: View {
    let state: ProviderState
    let now: Date
    let showCost: Bool
    let showRemaining: Bool

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
                ForEach(limits.windows.prefix(3)) { window in
                    LimitRow(window: window, tint: provider.tint, now: now, dense: true, showRemaining: showRemaining)
                }
            } else {
                Text(state.liveError != nil
                     ? "\(state.liveErrorHint ?? "Can't load limits"). Click for details."
                     : "No limit data yet. Click to set up.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func todayText(_ totals: UsageTotals) -> String {
        let tokens = "\(Format.tokens(totals.tokens.total)) tokens today"
        guard showCost, totals.cost > 0 else { return tokens }
        return "\(tokens) · ≈\(Format.cost(totals.cost))"
    }
}
