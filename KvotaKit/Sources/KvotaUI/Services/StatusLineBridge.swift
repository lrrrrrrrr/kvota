import Foundation
import KvotaCore

/// Installs Kvota's bridge as Claude Code's status line command and reads what it saves.
///
/// Claude Code passes the account's 5-hour and weekly usage to status line commands; the
/// bridge stores that in `~/.claude/kvota/rate_limits.json` and then runs the user's
/// previous status line command, if any. See ``StatusLineBridgeScript``.
struct StatusLineBridge: Sendable {
    let claudeHome: URL

    var folder: URL { claudeHome.appendingPathComponent("kvota", isDirectory: true) }
    var scriptURL: URL { folder.appendingPathComponent(StatusLineBridgeScript.fileName) }
    var snapshotURL: URL { folder.appendingPathComponent(StatusLineBridgeScript.snapshotFileName) }
    var previousCommandURL: URL { folder.appendingPathComponent(StatusLineBridgeScript.previousCommandFileName) }
    var lastRunURL: URL { folder.appendingPathComponent(StatusLineBridgeScript.lastRunFileName) }

    func readLastRun() -> StatusLineRun? {
        guard let data = try? Data(contentsOf: lastRunURL) else { return nil }
        return StatusLineRun.parse(data)
    }

    /// Keeps an installed bridge script in step with the one this version of Kvota ships.
    func updateScriptIfNeeded() {
        guard isInstalled() else { return }
        let current = try? String(contentsOf: scriptURL, encoding: .utf8)
        guard current != StatusLineBridgeScript.source else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data(StatusLineBridgeScript.source.utf8).write(to: scriptURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }
    var settingsURL: URL { claudeHome.appendingPathComponent("settings.json") }
    var backupURL: URL { claudeHome.appendingPathComponent("settings.json.kvota-backup") }

    func readSnapshot() -> LimitsSnapshot? {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: snapshotURL.path),
              let data = try? Data(contentsOf: snapshotURL) else { return nil }
        let captured = (attributes[.modificationDate] as? Date) ?? Date()
        return ClaudeLimits.parseStatusLine(data, capturedAt: captured)
    }

    func isInstalled() -> Bool {
        currentCommand()?.contains(StatusLineBridgeScript.marker) ?? false
    }

    func currentCommand() -> String? {
        (readSettings()?["statusLine"] as? [String: Any])?["command"] as? String
    }

    func install() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(StatusLineBridgeScript.source.utf8).write(to: scriptURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        var settings: [String: Any] = [:]
        if fm.fileExists(atPath: settingsURL.path) {
            let data = try Data(contentsOf: settingsURL)
            if !data.isEmpty {
                guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw KvotaError("~/.claude/settings.json could not be read as JSON, so Kvota left it untouched.")
                }
                settings = parsed
            }
            if !fm.fileExists(atPath: backupURL.path) {
                try data.write(to: backupURL)
            }
        }

        var statusLine = settings["statusLine"] as? [String: Any] ?? [:]
        let previous = (statusLine["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !previous.isEmpty, !previous.contains(StatusLineBridgeScript.marker) {
            try Data(previous.utf8).write(to: previousCommandURL, options: .atomic)
        } else if previous.isEmpty {
            try? fm.removeItem(at: previousCommandURL)
        }
        statusLine["type"] = "command"
        statusLine["command"] = Self.shellQuoted(scriptURL.path)
        settings["statusLine"] = statusLine
        try write(settings)
    }

    func uninstall() throws {
        let fm = FileManager.default
        if var settings = readSettings(),
           var statusLine = settings["statusLine"] as? [String: Any],
           (statusLine["command"] as? String)?.contains(StatusLineBridgeScript.marker) == true {
            let previous = (try? String(contentsOf: previousCommandURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if previous.isEmpty {
                settings.removeValue(forKey: "statusLine")
            } else {
                statusLine["command"] = previous
                settings["statusLine"] = statusLine
            }
            try write(settings)
        }
        try? fm.removeItem(at: previousCommandURL)
        try? fm.removeItem(at: scriptURL)
    }

    private func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func write(_ settings: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }

    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
