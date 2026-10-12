// swift-tools-version: 6.0
import PackageDescription

var targets: [Target] = [
    .target(name: "NarratorCore", resources: [.process("Resources")]),
    .testTarget(name: "NarratorCoreTests", dependencies: ["NarratorCore"]),
]

// macOS-only targets are left out on Linux so NarratorCore can be built and tested there.
#if os(macOS)
targets += [
    .target(name: "NarratorMac", dependencies: ["NarratorCore"]),
    .executableTarget(name: "LifeNarrator", dependencies: ["NarratorMac"]),
    .executableTarget(name: "NarratorFixtures"),
]
#endif

let package = Package(
    name: "LifeNarrator",
    platforms: [.macOS(.v14)],
    targets: targets
)
