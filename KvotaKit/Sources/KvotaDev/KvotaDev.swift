import KvotaUI

/// `swift run kvota-dev` starts Kvota without Xcode.
/// Some features (login item, notifications) need the real app bundle.
@main
enum KvotaDevMain {
    @MainActor
    static func main() {
        KvotaApp.main()
    }
}
