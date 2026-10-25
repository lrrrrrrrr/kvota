import KvotaCore
import SwiftUI

/// The window that opens from the menu bar icon.
struct MenuContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            if model.visibleProviders.isEmpty {
                Text("All providers are hidden. Turn one on in Settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(20)
            } else {
                VStack(spacing: 8) {
                    ForEach(model.visibleProviders) { provider in
                        ProviderCard(state: model.state(for: provider))
                    }
                }
                .padding(10)
            }
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 340)
        .onAppear { model.menuOpened() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Kvota")
                .font(.system(size: 13, weight: .semibold))
            if let refreshed = model.lastRefresh {
                Text("updated \(Format.ago(refreshed, now: model.now))")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            IconButton(symbol: "arrow.clockwise", help: "Refresh now") {
                model.refreshNow()
            }
            .opacity(model.isRefreshing ? 0.4 : 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            IconButton(
                symbol: model.settings.widgetVisible ? "rectangle.inset.topright.filled" : "rectangle.inset.topright",
                title: model.settings.widgetVisible ? "Hide widget" : "Show widget"
            ) {
                model.setWidgetVisible(!model.settings.widgetVisible)
            }
            Spacer()
            IconButton(symbol: "gearshape", title: "Settings") {
                model.openSettings()
            }
            IconButton(symbol: "power", title: "Quit") {
                model.quit()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// A plain, compact button: an SF Symbol with an optional title.
struct IconButton: View {
    let symbol: String
    var title: String?
    var help: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                if let title {
                    Text(title).font(.system(size: 11))
                }
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help ?? title ?? "")
    }
}

/// Everything about one provider: limits, usage today, a seven-day sparkline.
struct ProviderCard: View {
    @Environment(AppModel.self) private var model
    let state: ProviderState

    init(state: ProviderState) {
        self.state = state
    }

    private var provider: ProviderID { state.provider }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ProviderDot(provider: provider)
                Text(provider.displayName)
                    .font(.system(size: 12, weight: .semibold))
                if let plan = state.limits?.plan {
                    PlanBadge(text: plan)
                }
                Spacer()
                if let limits = state.limits {
                    Text("\(limits.source.displayName) · \(Format.ago(limits.capturedAt, now: model.now))")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .help(sourceHelp(limits.source))
                }
            }
            content
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    @ViewBuilder
    private var content: some View {
        switch state.access {
        case .needsPermission:
            VStack(alignment: .leading, spacing: 6) {
                Text("Kvota needs permission to read \(provider.homeFolderName) for \(provider.toolName) usage.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Grant Access…") { model.grantAccess(for: provider) }
                    .controlSize(.small)
            }
        case .notInstalled where state.liveLimits == nil:
            Text("No \(provider.toolName) data in \(model.homeDisplayPath(for: provider)) yet.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        default:
            if let limits = state.limits, !limits.windows.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(limits.windows.prefix(4)) { window in
                        LimitRow(window: window, tint: provider.tint, now: model.now, showRemaining: model.settings.showRemaining)
                    }
                }
                if let detail = limits.detail {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            } else {
                limitsHint
            }
            if let error = state.liveError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if state.usage?.hasActivity != true {
                    Button("Not using \(provider.displayName)? Hide it") {
                        model.settings.enabledProviders.remove(provider)
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 10))
                }
            }
            usageLine
        }
    }

    @ViewBuilder
    private var limitsHint: some View {
        let liveSupported = model.supportsLiveLimits(for: provider)
        let liveOn = liveSupported && model.settings.liveProviders.contains(provider)
        let offerLive = liveSupported && !liveOn
        let offerBridge = provider == .claude && !state.bridgeInstalled
        VStack(alignment: .leading, spacing: 6) {
            // With an error below, that error says what to do; a second hint would contradict it.
            if !(liveOn && state.liveError != nil) {
                Text(hintText(liveSupported: liveSupported, liveOn: liveOn))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if offerLive || offerBridge {
                HStack(spacing: 8) {
                    if offerLive {
                        Button("Show live limits") {
                            model.settings.liveProviders.insert(provider)
                        }
                        .controlSize(.small)
                    }
                    if offerBridge {
                        Button("Connect status line") { model.installBridge() }
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private func hintText(liveSupported: Bool, liveOn: Bool) -> String {
        if liveOn && state.liveError == nil {
            return "Checking your \(provider.displayName) plan limits…"
        }
        switch provider {
        case .claude:
            if state.bridgeInstalled {
                return ClaudeBridgeStatus.message(for: state.bridgeLastRun, now: model.now)
            }
            return liveSupported
                ? "Show your 5-hour and weekly limits live, or connect Claude Code's status line."
                : "Connect Claude Code's status line to see your 5-hour and weekly limits."
        case .codex:
            return liveSupported && !liveOn
                ? "Limits appear after your next Codex reply, or show them live now."
                : "Limits appear after your next Codex reply."
        case .gemini:
            return liveSupported
                ? "Gemini CLI doesn't keep its quota on your Mac. Show it live."
                : "Gemini CLI doesn't keep its quota on your Mac."
        }
    }

    @ViewBuilder
    private var usageLine: some View {
        if let usage = state.usage, usage.hasActivity {
            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Today")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                    Text(totalsText(usage.today))
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("7 days")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                    Text(totalsText(usage.last7Days))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Sparkline(values: usage.daily.map { Double($0.totals.tokens.total) }, color: provider.tint)
                    .frame(width: 62, height: 20)
            }
            .help(modelBreakdown(usage))
        }
    }

    private func totalsText(_ totals: UsageTotals) -> String {
        let tokens = Format.tokens(totals.tokens.total)
        guard model.settings.showCost, totals.cost > 0 else { return tokens }
        return "\(tokens) · ≈\(Format.cost(totals.cost))"
    }

    private func modelBreakdown(_ usage: ProviderUsageSummary) -> String {
        var lines = usage.models.prefix(6).map { item in
            "\(Format.modelName(item.model)): \(Format.tokens(item.totals.tokens.total)) tokens, \(item.totals.requests) requests"
        }
        if model.settings.showCost {
            lines.append("Costs are estimates at public API prices.")
        }
        return lines.joined(separator: "\n")
    }

    private func sourceHelp(_ source: LimitSource) -> String {
        switch source {
        case .sessionLog: "Read from \(provider.toolName)'s own session log on this Mac."
        case .statusLine: "Saved by Kvota's status line bridge after Claude Code's last reply."
        case .estimate: "Worked out from Claude Code's logs on this Mac. Claude doesn't publish exact limits locally, so 100% means your heaviest 5-hour session so far."
        case .live: "Fetched from \(provider.displayName)'s usage endpoint with your existing \(provider.toolName) login."
        }
    }
}
