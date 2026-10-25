import AppKit
import KvotaCore

/// Finds each tool's data folder.
///
/// The direct build reads `~/.claude`, `~/.codex` and `~/.gemini` directly. The App Store
/// build is sandboxed, so the user picks each folder once in an open panel and Kvota keeps
/// a security-scoped bookmark to it.
@MainActor
final class FolderAccess {
    let isSandboxed = KvotaEnvironment.isSandboxed
    private var granted: [ProviderID: URL] = [:]

    func defaultURL(for provider: ProviderID) -> URL {
        KvotaEnvironment.realHome.appendingPathComponent(provider.homeFolderName, isDirectory: true)
    }

    /// The folder to read, or nil when it is missing or not yet granted.
    func url(for provider: ProviderID) -> URL? {
        if isSandboxed { return granted[provider] }
        let url = defaultURL(for: provider)
        return Self.isDirectory(url) ? url : nil
    }

    func status(for provider: ProviderID) -> DataAccess {
        if isSandboxed {
            return granted[provider] != nil ? .available : .needsPermission
        }
        return Self.isDirectory(defaultURL(for: provider)) ? .available : .notInstalled
    }

    func restore() {
        guard isSandboxed else { return }
        for provider in ProviderID.allCases {
            guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey(provider)) else { continue }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale),
                  url.startAccessingSecurityScopedResource()
            else { continue }
            granted[provider] = url
            if stale { saveBookmark(url, for: provider) }
        }
    }

    /// Shows an open panel pointed at the tool's folder. Returns true when access was granted.
    func requestAccess(for provider: ProviderID) -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = defaultURL(for: provider)
        panel.prompt = "Grant Access"
        panel.message = "Select the \(provider.homeFolderName) folder in your home folder so Kvota can read \(provider.toolName) usage."
            + (provider == .claude ? " Kvota writes there only if you connect the status line bridge." : " Kvota only reads it.")

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, var url = panel.url else { return false }

        // Picked the home folder instead of ~/.codex? Use the right child if it's there.
        if url.lastPathComponent != provider.homeFolderName {
            let child = url.appendingPathComponent(provider.homeFolderName, isDirectory: true)
            if Self.isDirectory(child) { url = child }
        }

        if isSandboxed {
            granted[provider]?.stopAccessingSecurityScopedResource()
            _ = url.startAccessingSecurityScopedResource()
            granted[provider] = url
            saveBookmark(url, for: provider)
        }
        return true
    }

    func revoke(_ provider: ProviderID) {
        granted[provider]?.stopAccessingSecurityScopedResource()
        granted[provider] = nil
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey(provider))
    }

    private func saveBookmark(_ url: URL, for provider: ProviderID) {
        if let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey(provider))
        }
    }

    private static func bookmarkKey(_ provider: ProviderID) -> String {
        "bookmark.\(provider.rawValue)"
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
