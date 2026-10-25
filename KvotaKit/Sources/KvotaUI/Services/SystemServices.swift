import Foundation
import ServiceManagement
import UserNotifications

/// Local notifications when a limit crosses the warning threshold.
@MainActor
final class Notifier {
    /// Notifications need a real app bundle; `swift run` builds don't have one.
    var isAvailable: Bool { KvotaEnvironment.isAppBundle }

    func requestAuthorization() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(title: String, body: String, id: String) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}

/// Open at login, through the system's login items (no helper app needed).
enum LoginItem {
    static var isAvailable: Bool { KvotaEnvironment.isAppBundle }

    static var isEnabled: Bool {
        isAvailable && SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        guard isAvailable else { return }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
