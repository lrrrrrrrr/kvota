import AppKit
import KvotaCore
import SwiftUI

/// Kvota's menu bar app. The floating widget and the settings window are AppKit
/// windows managed by ``AppModel``. Everything comes from files on this Mac: Kvota never
/// reads another app's sign-in and never contacts a provider.
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
    let model = AppModel()

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
