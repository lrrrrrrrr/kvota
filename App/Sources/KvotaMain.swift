import KvotaUI

/// Entry point for both app targets. They share all features; the App Store build
/// runs in the App Sandbox and asks for access to each tool's folder.
@main
enum KvotaMain {
    @MainActor
    static func main() {
        KvotaApp.main()
    }
}
