import AppKit
import KvotaCore
import SwiftUI

/// Hooks the app target can set before launch.
public enum KvotaRuntime {
    /// Live limits client. The direct-download build installs one; the App Store build
    /// leaves it empty and works from local files only.
    nonisolated(unsafe) public static var liveProvider: LiveLimitsProvider?
}

/// Kvota's menu bar app. The floating widget and the settings window are AppKit
/// windows managed by ``AppModel``.
public struct KvotaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    public init() {}

    public var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environment(appDelegate.model)
        } label: {
            MenuBarLabel()
                .environment(appDelegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel(liveProvider: KvotaRuntime.liveProvider)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // When launched from `swift run` there is no Info.plist saying "no Dock icon".
        if !KvotaEnvironment.isAppBundle {
            NSApp.setActivationPolicy(.accessory)
        }
        model.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
