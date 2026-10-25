import Foundation

enum KvotaEnvironment {
    /// True in the App Store build, which runs in the App Sandbox.
    static let isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    /// The user's real home folder, even inside the sandbox (where `NSHomeDirectory()`
    /// points at the app container).
    static let realHome: URL = {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }()

    /// False when running as a bare executable (`swift run kvota-dev`).
    static var isAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    static var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (short?, build?): return "\(short) (\(build))"
        case let (short?, nil): return short
        default: return "development build"
        }
    }

    static let repositoryURL = URL(string: "https://github.com/lrrrrrrrr/kvota")!

    /// "~/.claude" rather than "/Users/name/.claude".
    static func displayPath(_ url: URL) -> String {
        let path = url.path
        let home = realHome.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
