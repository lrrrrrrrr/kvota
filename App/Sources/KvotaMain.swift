import KvotaUI
#if KVOTA_DIRECT
import KvotaLive
#endif

/// Entry point for both app targets. The direct-download build adds live limits; the
/// App Store build is sandboxed and reads local files only.
@main
enum KvotaMain {
    @MainActor
    static func main() {
        #if KVOTA_DIRECT
        KvotaRuntime.liveProvider = LiveLimitsClient()
        #endif
        KvotaApp.main()
    }
}
