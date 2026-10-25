// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StandUpTimer",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "StandUpTimerCore", targets: ["StandUpTimerCore"]),
        .executable(name: "StandUpTimerApp", targets: ["StandUpTimerApp"])
    ],
    targets: [
        .target(name: "StandUpTimerCore"),
        .executableTarget(
            name: "StandUpTimerApp",
            dependencies: ["StandUpTimerCore"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "StandUpTimerCoreTests",
            dependencies: ["StandUpTimerCore"]
        )
    ]
)
