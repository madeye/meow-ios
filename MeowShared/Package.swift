// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MeowShared",
    platforms: [
        .iOS(.v26),
        // macOS 15 lets `swift test` drive MeowSharedTests from the command
        // line. Production builds always target iOS via `project.yml`; this
        // declaration is only so CI / local dev can run pure-logic tests
        // without spinning up a simulator.
        .macOS(.v15),
    ],
    products: [
        .library(name: "MeowModels", targets: ["MeowModels"]),
        .library(name: "MeowIPC", targets: ["MeowIPC"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.3"),
    ],
    targets: [
        .target(
            name: "MeowModels",
            dependencies: [
                .product(name: "Yams", package: "Yams"),
            ],
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
