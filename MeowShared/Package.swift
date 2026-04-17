// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeowShared",
    platforms: [
        .iOS(.v26),
    ],
    products: [
        .library(name: "MeowModels", targets: ["MeowModels"]),
        .library(name: "MeowIPC", targets: ["MeowIPC"]),
    ],
    targets: [
        .target(
            name: "MeowModels",
            path: "Sources/MeowModels"
        ),
        .target(
            name: "MeowIPC",
            dependencies: ["MeowModels"],
            path: "Sources/MeowIPC"
        ),
        .testTarget(
            name: "MeowSharedTests",
            dependencies: ["MeowModels", "MeowIPC"],
            path: "Tests/MeowSharedTests"
        ),
    ]
)
