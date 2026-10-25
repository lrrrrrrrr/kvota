import AppKit
import KvotaCore
import Observation

/// Whether Kvota can read a provider's data folder.
public enum DataAccess: Equatable, Sendable {
    case unknown
    case available
    /// The tool's folder doesn't exist on this Mac.
    case notInstalled
    /// App Store build: the user hasn't granted access to the folder yet.
    case needsPermission
}

/// What Kvota currently knows about one provider.
public struct ProviderState: Equatable {
    public let provider: ProviderID
    public var usage: ProviderUsageSummary?
    /// Limits read from local files (Codex session logs, Claude status line bridge).
    public var localLimits: LimitsSnapshot?
    public var liveLimits: LimitsSnapshot?
    public var liveError: String?
    public var access: DataAccess = .unknown
    public var bridgeInstalled = false

    public init(provider: ProviderID) {
        self.provider = provider
    }

    /// The freshest limits reading from any source.
    public var limits: LimitsSnapshot? {
        LimitsSnapshot.newest(localLimits, liveLimits)
    }

    public func highestPercent(at now: Date) -> Double? {
        limits?.highestUsedPercent(at: now)
    }
}

/// App state and coordination: scanning, live refresh, the widget, alerts.
@MainActor
@Observable
public final class AppModel {
    public var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            if persistsSettings { settings.save() }
            settingsChanged(from: oldValue)
        }
    }

    public private(set) var states: [ProviderID: ProviderState]
    /// Updated every minute so countdowns and expired windows re-render.
    public private(set) var now = Date()
    public private(set) var lastRefresh: Date?
    public private(set) var isRefreshing = false
    public private(set) var bridgeMessage: String?
    /// The floating widget shows every detail while expanded (toggled by clicking it).
    public var widgetExpanded = false

    public let liveProvider: LiveLimitsProvider?

    let access = FolderAccess()
    private let store = UsageStore()
    private let widget = FloatingWidgetController()
    private let notifier = Notifier()
    private let persistsSettings: Bool

    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var watchedPaths: [String] = []
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var rescanRequested = false
    @ObservationIgnored private var lastLiveFetch: [ProviderID: Date] = [:]
    @ObservationIgnored private var liveInFlight: Set<ProviderID> = []
    @ObservationIgnored private var started = false
    @ObservationIgnored private var firedAlerts: [String]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Preview models show fixed data and never scan or fetch.
    @ObservationIgnored private var isPreview = false

    public init(liveProvider: LiveLimitsProvider?) {
        self.liveProvider = liveProvider
        var loaded = AppSettings.load()
        if loaded.settingsVersion < AppSettings.currentVersion {
            // Version 2: live limits are on by default wherever the build supports them,
            // so subscription limits show up without any setup.
            if let liveProvider {
                loaded.liveProviders.formUnion(liveProvider.supportedProviders)
            }
            loaded.settingsVersion = AppSettings.currentVersion
            loaded.save()
        }
        self.settings = loaded
        self.persistsSettings = true
        self.states = Dictionary(uniqueKeysWithValues: ProviderID.allCases.map { ($0, ProviderState(provider: $0)) })
        self.firedAlerts = UserDefaults.standard.stringArray(forKey: "firedAlerts") ?? []
    }

    /// A model filled with fixed data, for previews and snapshot tests. Does nothing on its own.
    init(preview settings: AppSettings, states: [ProviderState], now: Date, liveProvider: LiveLimitsProvider? = nil) {
        self.liveProvider = liveProvider
        self.settings = settings
        self.persistsSettings = false
        var all = Dictionary(uniqueKeysWithValues: ProviderID.allCases.map { ($0, ProviderState(provider: $0)) })
        for state in states { all[state.provider] = state }
        self.states = all
        self.firedAlerts = []
        // Re-assign defaulted properties only after every stored property is initialized.
        self.now = now
        self.lastRefresh = now
        self.isPreview = true
    }

    // MARK: - Reading state

    public var visibleProviders: [ProviderID] {
        ProviderID.allCases.filter { settings.enabledProviders.contains($0) }
    }

    public func state(for provider: ProviderID) -> ProviderState {
        states[provider] ?? ProviderState(provider: provider)
    }

    /// Highest usage across visible providers, for the menu bar.
    public func highestPercent() -> Double? {
        visibleProviders.compactMap { state(for: $0).highestPercent(at: now) }.max()
    }

    public var supportsLiveLimits: Bool { liveProvider != nil }

    public func supportsLiveLimits(for provider: ProviderID) -> Bool {
        liveProvider?.supportedProviders.contains(provider) ?? false
    }

    public var isSandboxed: Bool { access.isSandboxed }

    func homeDisplayPath(for provider: ProviderID) -> String {
        KvotaEnvironment.displayPath(access.url(for: provider) ?? access.defaultURL(for: provider))
    }

    // MARK: - Lifecycle

    public func start() {
        guard !started else { return }
        started = true

        access.restore()
        refreshAccess()
        rebuildWatcher()
        widget.attach(self)
        scheduleScan(after: 0)
        refreshLive(minimumInterval: 0)
        startTicker()

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleScan(after: 2)
                self?.refreshLive(minimumInterval: 0)
            }
        })

        if settings.notificationsEnabled { notifier.requestAuthorization() }
        if !settings.hasLaunchedBefore {
            settings.hasLaunchedBefore = true
            openSettings(.providers)
        }
    }

    /// Called when the menu bar window opens: make sure what it shows is current.
    public func menuOpened() {
        guard !isPreview else { return }
        now = Date()
        scheduleScan(after: 0)
        refreshLive(minimumInterval: 60)
    }

    public func refreshNow() {
        scheduleScan(after: 0)
        refreshLive(minimumInterval: 0)
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            var minutes = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                guard let self else { return }
                minutes += 1
                self.now = Date()
                if minutes % 5 == 0 {
                    // Safety net in case a file event was missed; unchanged files cost one stat.
                    self.rebuildWatcher()
                    self.scheduleScan(after: 0)
                } else {
                    await self.refreshSummaries()
                }
                self.refreshLive(minimumInterval: Double(self.settings.liveRefreshMinutes) * 60)
            }
        }
    }

    // MARK: - Settings

    private func settingsChanged(from old: AppSettings) {
        if settings.enabledProviders != old.enabledProviders {
            refreshAccess()
            rebuildWatcher()
            scheduleScan(after: 0)
        }
        if settings.liveProviders != old.liveProviders {
            for provider in old.liveProviders.subtracting(settings.liveProviders) {
                update(provider) {
                    $0.liveLimits = nil
                    $0.liveError = nil
                }
                lastLiveFetch[provider] = nil
            }
            refreshLive(minimumInterval: 0)
        }
        if settings.notificationsEnabled && !old.notificationsEnabled {
            notifier.requestAuthorization()
            evaluateAlerts()
        }
        widget.sync()
    }

    // MARK: - Data access

    func refreshAccess() {
        for provider in ProviderID.allCases {
            let status = access.status(for: provider)
            update(provider) { $0.access = status }
        }
    }

    public func grantAccess(for provider: ProviderID) {
        guard access.requestAccess(for: provider) else { return }
        refreshAccess()
        rebuildWatcher()
        scheduleScan(after: 0)
    }

    public func revokeAccess(for provider: ProviderID) {
        access.revoke(provider)
        let store = self.store
        Task { await store.forget(provider) }
        update(provider) {
            $0.usage = nil
            $0.localLimits = nil
            $0.bridgeInstalled = false
        }
        refreshAccess()
        rebuildWatcher()
    }

    // MARK: - Claude status line bridge

    public func installBridge() {
        guard let home = access.url(for: .claude) else {
            bridgeMessage = "Kvota needs access to ~/.claude first."
            return
        }
        do {
            try StatusLineBridge(claudeHome: home).install()
            bridgeMessage = "Connected. Limits appear after your next message in Claude Code."
            update(.claude) { $0.bridgeInstalled = true }
            // Show something right away instead of waiting for Claude Code.
            if supportsLiveLimits(for: .claude), !settings.liveProviders.contains(.claude) {
                settings.liveProviders.insert(.claude)
            }
        } catch {
            bridgeMessage = error.localizedDescription
        }
    }

    public func uninstallBridge() {
        guard let home = access.url(for: .claude) else { return }
        do {
            try StatusLineBridge(claudeHome: home).uninstall()
            bridgeMessage = "Disconnected. Your previous status line is restored."
            update(.claude) {
                $0.bridgeInstalled = false
                if $0.localLimits?.source == .statusLine { $0.localLimits = nil }
            }
        } catch {
            bridgeMessage = error.localizedDescription
        }
    }

    // MARK: - Scanning

    func scheduleScan(after delay: TimeInterval = 0.4) {
        guard !isPreview else { return }
        if scanTask != nil {
            rescanRequested = true
            return
        }
        scanTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            await self?.runScan()
            guard let self else { return }
            self.scanTask = nil
            if self.rescanRequested {
                self.rescanRequested = false
                self.scheduleScan()
            }
        }
    }

    private func runScan() async {
        isRefreshing = true
        let now = Date()
        for provider in visibleProviders {
            guard let home = access.url(for: provider) else { continue }
            await store.scan(provider, home: home, now: now)
        }
        await refreshSummaries()
        lastRefresh = Date()
        isRefreshing = false
    }

    private func refreshSummaries() async {
        let now = Date()
        self.now = now
        for provider in visibleProviders {
            guard let home = access.url(for: provider) else {
                update(provider) {
                    $0.usage = nil
                    $0.localLimits = nil
                }
                continue
            }
            let summary = await store.summary(provider, now: now)
            var localLimits = await store.limitsFromLogs(provider)
            var bridgeInstalled = false
            if provider == .claude {
                let bridge = StatusLineBridge(claudeHome: home)
                let result = await Task.detached(priority: .utility) { (bridge.readSnapshot(), bridge.isInstalled()) }.value
                localLimits = result.0
                bridgeInstalled = result.1
            }
            update(provider) {
                $0.usage = summary
                $0.localLimits = localLimits
                if provider == .claude { $0.bridgeInstalled = bridgeInstalled }
            }
        }
        evaluateAlerts()
    }

    private func rebuildWatcher() {
        var paths: [String] = []
        let fm = FileManager.default
        for provider in visibleProviders {
            guard let home = access.url(for: provider) else { continue }
            var folders = provider.logFolders.map { home.appendingPathComponent($0).path }
            if provider == .claude { folders.append(home.appendingPathComponent("kvota").path) }
            let existing = folders.filter { fm.fileExists(atPath: $0) }
            // Until the tool has written logs, watch its home so the first session is noticed.
            paths += existing.isEmpty ? [home.path] : existing
        }
        guard paths != watchedPaths else { return }
        watchedPaths = paths
        watcher = paths.isEmpty ? nil : DirectoryWatcher(paths: paths, latency: 2) { [weak self] in
            Task { @MainActor in self?.scheduleScan() }
        }
    }

    // MARK: - Live limits

    func refreshLive(minimumInterval: TimeInterval) {
        guard !isPreview, let live = liveProvider else { return }
        let now = Date()
        for provider in visibleProviders
        where settings.liveProviders.contains(provider) && live.supportedProviders.contains(provider) {
            if liveInFlight.contains(provider) { continue }
            if let last = lastLiveFetch[provider], now.timeIntervalSince(last) < minimumInterval { continue }
            let home = access.url(for: provider) ?? access.defaultURL(for: provider)
            liveInFlight.insert(provider)
            lastLiveFetch[provider] = now
            Task { [weak self] in
                do {
                    let snapshot = try await live.fetchLimits(for: provider, home: home)
                    self?.update(provider) {
                        $0.liveLimits = snapshot
                        $0.liveError = nil
                    }
                } catch {
                    self?.update(provider) { $0.liveError = error.localizedDescription }
                }
                self?.liveInFlight.remove(provider)
                self?.evaluateAlerts()
            }
        }
    }

    // MARK: - Alerts

    private func evaluateAlerts() {
        guard settings.notificationsEnabled, notifier.isAvailable else { return }
        let now = Date()
        let thresholds = Array(Set([settings.warnThreshold, 95])).sorted()
        var changed = false
        for provider in visibleProviders {
            guard let limits = state(for: provider).limits else { continue }
            for window in limits.windows {
                let used = window.usedPercent(at: now)
                guard let threshold = thresholds.last(where: { used >= Double($0) }) else { continue }
                let reset = Int(window.resetsAt?.timeIntervalSince1970 ?? 0)
                let key = "\(provider.rawValue)|\(window.id)|\(threshold)|\(reset)"
                guard !firedAlerts.contains(key) else { continue }
                firedAlerts.append(key)
                changed = true
                let body = window.resetsAt.map { "Resets in \(Format.countdown(to: $0, from: now))." } ?? ""
                notifier.post(
                    title: "\(provider.displayName): \(window.label) limit at \(Format.percent(used))",
                    body: body,
                    id: key
                )
            }
        }
        if changed {
            firedAlerts = Array(firedAlerts.suffix(200))
            UserDefaults.standard.set(firedAlerts, forKey: "firedAlerts")
        }
    }

    // MARK: - Windows

    public func openSettings(_ tab: SettingsTab = .general) {
        SettingsWindowController.shared.show(model: self, tab: tab)
    }

    public func setWidgetVisible(_ visible: Bool) {
        settings.widgetVisible = visible
    }

    public func resetWidgetPosition() {
        widget.resetPosition()
    }

    public func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    private func update(_ provider: ProviderID, _ change: (inout ProviderState) -> Void) {
        var state = states[provider] ?? ProviderState(provider: provider)
        change(&state)
        if states[provider] != state {
            states[provider] = state
        }
    }
}
