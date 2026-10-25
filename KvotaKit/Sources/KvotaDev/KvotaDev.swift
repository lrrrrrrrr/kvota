import KvotaLive
import KvotaUI

/// `swift run kvota-dev` starts Kvota without Xcode, with live limits available.
/// Some features (login item, notifications) need the real app bundle.
@main
enum KvotaDevMain {
    @MainActor
    static func main() {
        KvotaRuntime.liveProvider = LiveLimitsClient()
        KvotaApp.main()
    }
}
