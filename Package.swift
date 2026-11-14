// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Perch",
    platforms: [.macOS(.v14)],
    targets: [
        // Logic without any UI: track timing, island geometry, parsing what players
        // report. Kept separate so it can be tested on its own (Scripts/check.sh).
        .target(name: "PerchCore", path: "Sources/PerchCore"),
        .executableTarget(name: "Perch", dependencies: ["PerchCore"], path: "Sources/Perch"),
        .testTarget(name: "PerchCoreTests", dependencies: ["PerchCore"], path: "Tests/PerchCoreTests"),
    ]
)
