import Foundation
import KvotaCore

public enum MenuBarStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Gauge icon plus the highest usage across providers.
    case highest
    /// One short value per provider.
    case perProvider
    /// Just the icon.
    case iconOnly

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .highest: "Icon and the limit closest to running out"
        case .perProvider: "Usage per provider"
        case .iconOnly: "Icon only"
        }
    }
}

public enum WidgetStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case compact
    case detailed

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .compact: "Compact"
        case .detailed: "Detailed"
        }
    }
}

/// Everything the user can configure. Stored as one JSON blob in UserDefaults; unknown
/// or missing keys fall back to defaults, so new settings never break old installs.
public struct AppSettings: Codable, Equatable, Sendable {
    public var enabledProviders: Set<ProviderID> = Set(ProviderID.allCases)
    public var menuBarStyle: MenuBarStyle = .highest
    public var showCost = true
    /// Show what's left of each limit ("38% left") rather than what's used.
    public var showRemaining = true

    public var widgetVisible = true
    public var widgetStyle: WidgetStyle = .compact
    public var widgetOpacity = 0.9
    public var widgetFadeWhenIdle = true
    public var widgetClickThrough = false
    public var widgetOnTop = true
    public var widgetAllSpaces = true

    /// Providers whose limits are also fetched live (direct build only).
    public var liveProviders: Set<ProviderID> = []
    public var liveRefreshMinutes = 5

    public var notificationsEnabled = false
    public var warnThreshold = 80

    public var hasLaunchedBefore = false
    /// Bumped when defaults change in a way existing installs should pick up.
    public var settingsVersion = 0
    public static let currentVersion = 2

    public init() {}

    enum CodingKeys: String, CodingKey {
        case enabledProviders, menuBarStyle, showCost, showRemaining
        case widgetVisible, widgetStyle, widgetOpacity, widgetFadeWhenIdle, widgetClickThrough, widgetOnTop, widgetAllSpaces
        case liveProviders, liveRefreshMinutes
        case notificationsEnabled, warnThreshold
        case hasLaunchedBefore, settingsVersion
    }

    private static let defaultsKey = "settings.v1"

    public static func load(from defaults: UserDefaults = .standard) -> AppSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return settings
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

extension AppSettings {
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        enabledProviders = value(.enabledProviders, enabledProviders)
        menuBarStyle = value(.menuBarStyle, menuBarStyle)
        showCost = value(.showCost, showCost)
        showRemaining = value(.showRemaining, showRemaining)
        widgetVisible = value(.widgetVisible, widgetVisible)
        widgetStyle = value(.widgetStyle, widgetStyle)
        widgetOpacity = min(1, max(0.3, value(.widgetOpacity, widgetOpacity)))
        widgetFadeWhenIdle = value(.widgetFadeWhenIdle, widgetFadeWhenIdle)
        widgetClickThrough = value(.widgetClickThrough, widgetClickThrough)
        widgetOnTop = value(.widgetOnTop, widgetOnTop)
        widgetAllSpaces = value(.widgetAllSpaces, widgetAllSpaces)
        liveProviders = value(.liveProviders, liveProviders)
        liveRefreshMinutes = max(1, value(.liveRefreshMinutes, liveRefreshMinutes))
        notificationsEnabled = value(.notificationsEnabled, notificationsEnabled)
        warnThreshold = min(99, max(10, value(.warnThreshold, warnThreshold)))
        hasLaunchedBefore = value(.hasLaunchedBefore, hasLaunchedBefore)
        settingsVersion = value(.settingsVersion, settingsVersion)
    }
}
