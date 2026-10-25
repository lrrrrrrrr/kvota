import AppKit
import KvotaCore
import SwiftUI

public enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case general, providers, widget, about
    public var id: String { rawValue }
}

/// Hosts the settings in a regular window, which behaves better than the SwiftUI
/// `Settings` scene in an app without a Dock icon.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    private let selection = SettingsSelection()

    func show(model: AppModel, tab: SettingsTab) {
        selection.tab = tab
        if window == nil {
            let root = SettingsView(selection: selection).environment(model)
            let window = NSWindow(contentViewController: NSHostingController(rootView: root))
            window.title = "Kvota Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            _ = window.setFrameAutosaveName("KvotaSettings")
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
@Observable
final class SettingsSelection {
    var tab: SettingsTab = .general
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.kvotaSnapshotMode) private var snapshotMode
    @Bindable var selection: SettingsSelection

    var body: some View {
        TabView(selection: $selection.tab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            ProvidersSettings()
                .tabItem { Label("Providers", systemImage: "square.stack.3d.up") }
                .tag(SettingsTab.providers)
            WidgetSettings()
                .tabItem { Label("Widget", systemImage: "rectangle.inset.topright.filled") }
                .tag(SettingsTab.widget)
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        // Screenshots show whole sections instead of a scrolled view.
        .frame(width: 560, height: snapshotMode ? 582 : 560)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Open Kvota at login", isOn: $launchAtLogin)
                    .disabled(!LoginItem.isAvailable)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            try LoginItem.setEnabled(enabled)
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = LoginItem.isEnabled
                        }
                    }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Menu bar") {
                Picker("Show", selection: $model.settings.menuBarStyle) {
                    ForEach(MenuBarStyle.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Show what's left of each limit (instead of what's used)", isOn: $model.settings.showRemaining)
                Toggle("Show estimated API cost next to token counts", isOn: $model.settings.showCost)
            }

            Section {
                Toggle("Notify me when a limit gets close", isOn: $model.settings.notificationsEnabled)
                Picker("Warn at", selection: $model.settings.warnThreshold) {
                    ForEach([50, 70, 75, 80, 85, 90], id: \.self) { Text("\($0)%").tag($0) }
                }
                .disabled(!model.settings.notificationsEnabled)
            } header: {
                Text("Alerts")
            } footer: {
                Text("One notification per limit window at your threshold, and again at 95%.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Providers

private struct ProvidersSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            ForEach(ProviderID.allCases) { provider in
                ProviderSection(provider: provider)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ProviderSection: View {
    @Environment(AppModel.self) private var model
    let provider: ProviderID

    var body: some View {
        let state = model.state(for: provider)
        Section {
            Toggle("Show \(provider.displayName)", isOn: membership(\.enabledProviders))

            LabeledContent("Data folder") {
                HStack(spacing: 6) {
                    Text(model.homeDisplayPath(for: provider))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    accessBadge(state.access)
                    if model.isSandboxed {
                        Button(state.access == .available ? "Change…" : "Grant Access…") {
                            model.grantAccess(for: provider)
                        }
                        .controlSize(.small)
                    }
                }
            }

            LabeledContent("Limits") {
                Text(limitsSourceText)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }

            if provider == .claude {
                bridgeRow(state)
            }
        } header: {
            HStack(spacing: 6) {
                ProviderDot(provider: provider, size: 8)
                Text(provider.toolName)
            }
        }
    }

    @ViewBuilder
    private func bridgeRow(_ state: ProviderState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Status line bridge")
                    Text("Claude Code shares your 5-hour and weekly usage with its status line. The bridge saves that for Kvota and keeps your current status line working. If you had none, Claude Code shows a short one with your model and limits.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if state.bridgeInstalled {
                    Button("Disconnect") { model.uninstallBridge() }
                } else {
                    Button("Connect") { model.installBridge() }
                        .disabled(state.access != .available)
                }
            }
            if let message = model.bridgeMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func accessBadge(_ access: DataAccess) -> some View {
        switch access {
        case .available:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Kvota can read this folder")
        case .needsPermission:
            Image(systemName: "lock.circle").foregroundStyle(.orange).help("Kvota needs your permission to read this folder")
        case .notInstalled:
            Image(systemName: "questionmark.circle").foregroundStyle(.secondary).help("Folder not found. Is \(provider.toolName) installed?")
        case .unknown:
            EmptyView()
        }
    }

    private var limitsSourceText: String {
        switch provider {
        case .claude: "From Claude Code's status line"
        case .codex: "From Codex's session logs"
        case .gemini: "Not shown: Gemini CLI keeps no quota on your Mac"
        }
    }

    private func membership(_ keyPath: WritableKeyPath<AppSettings, Set<ProviderID>>) -> Binding<Bool> {
        Binding(
            get: { model.settings[keyPath: keyPath].contains(provider) },
            set: { on in
                if on {
                    model.settings[keyPath: keyPath].insert(provider)
                } else {
                    model.settings[keyPath: keyPath].remove(provider)
                }
            }
        )
    }
}

// MARK: - Widget

private struct WidgetSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Show floating widget", isOn: $model.settings.widgetVisible)
                Picker("Style", selection: $model.settings.widgetStyle) {
                    ForEach(WidgetStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section("Behavior") {
                Toggle("Keep above other windows", isOn: $model.settings.widgetOnTop)
                Toggle("Show on every Space and over full-screen apps", isOn: $model.settings.widgetAllSpaces)
                Toggle("Fade when the pointer is elsewhere", isOn: $model.settings.widgetFadeWhenIdle)
                LabeledContent("Faded opacity") {
                    Slider(value: $model.settings.widgetOpacity, in: 0.3...1)
                        .frame(width: 200)
                        .disabled(!model.settings.widgetFadeWhenIdle)
                }
                Toggle(isOn: $model.settings.widgetClickThrough) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Click-through")
                        Text("Clicks pass to the window underneath. Turn this off here to move the widget again.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Button("Move Widget Back to the Top-Right Corner") { model.resetWidgetPosition() }
            } footer: {
                Text("Drag the widget to place it anywhere. Right-click it for quick options.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - About

private struct AboutSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 84, height: 84)
            VStack(spacing: 4) {
                Text("Kvota").font(.title2.weight(.semibold))
                Text(KvotaEnvironment.version).font(.callout).foregroundStyle(.secondary)
            }
            Text("Your Claude, Codex and Gemini limits at a glance.")
                .foregroundStyle(.secondary)
            Text(privacyText)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                Link("Source code", destination: KvotaEnvironment.repositoryURL)
                Link("How it works", destination: KvotaEnvironment.repositoryURL.appendingPathComponent("blob/main/docs/HOW_IT_WORKS.md"))
                Link("Report an issue", destination: KvotaEnvironment.repositoryURL.appendingPathComponent("issues"))
            }
            .font(.callout)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var privacyText: String {
        "Kvota reads usage from files the CLIs already keep on your Mac. It never reads your sign-ins and never connects to the internet."
    }
}
