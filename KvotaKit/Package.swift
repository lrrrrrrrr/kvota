// swift-tools-version:5.10
import PackageDescription

// KvotaCore is plain Foundation and builds on macOS and Linux, so the parsers can be
// tested anywhere. The UI, the live-limits clients and the dev launcher are macOS-only.
var products: [Product] = [
    .library(name: "KvotaCore", targets: ["KvotaCore"]),
]

var targets: [Target] = [
    .target(
        name: "KvotaCore",
        dependencies: [.product(name: "libzstd", package: "zstd")]
    ),
    .testTarget(
        name: "KvotaCoreTests",
        dependencies: ["KvotaCore", .product(name: "libzstd", package: "zstd")]
    ),
]

#if os(macOS)
products += [
    .library(name: "KvotaUI", targets: ["KvotaUI"]),
    .library(name: "KvotaLive", targets: ["KvotaLive"]),
    .executable(name: "kvota-dev", targets: ["KvotaDev"]),
]
targets += [
    .target(name: "KvotaUI", dependencies: ["KvotaCore"]),
    .target(name: "KvotaLive", dependencies: ["KvotaCore"]),
    .executableTarget(name: "KvotaDev", dependencies: ["KvotaUI", "KvotaLive"]),
    .testTarget(name: "KvotaUITests", dependencies: ["KvotaUI"]),
]
#endif

let package = Package(
    name: "KvotaKit",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: [
        // Codex compresses session logs older than seven days with zstd.
        .package(url: "https://github.com/facebook/zstd.git", exact: "1.5.7"),
    ],
    targets: targets
)
