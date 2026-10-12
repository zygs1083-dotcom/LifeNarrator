// swift-tools-version: 6.0
import PackageDescription

var dependencies: [Package.Dependency] = []

var targets: [Target] = [
    .target(name: "NarratorCore", resources: [.process("Resources")]),
    .testTarget(name: "NarratorCoreTests", dependencies: ["NarratorCore"]),
]

// macOS-only targets are left out on Linux so NarratorCore can be built and tested there.
#if os(macOS)
dependencies.append(.package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "3.1.0"))
targets += [
    .binaryTarget(
        name: "LlamaFramework",
        url: "https://github.com/ggml-org/llama.cpp/releases/download/b11429/llama-b11429-xcframework.zip",
        checksum: "e26a6a0a813f5760fe45834ce239d5b525e4e2442d4fd017221d9f0438383174"
    ),
    .target(name: "NarratorMac", dependencies: ["NarratorCore", "LlamaFramework",
        .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")], resources: [.process("Resources")]),
    .executableTarget(name: "narrator-bench", dependencies: ["NarratorMac"]),
    .executableTarget(name: "context-probe", dependencies: ["NarratorMac", "NarratorCore"], exclude: ["README.md"]),
    .testTarget(name: "NarratorMacTests", dependencies: ["NarratorMac"]),
    .executableTarget(name: "LifeNarrator", dependencies: ["NarratorMac"]),
    .executableTarget(name: "NarratorFixtures"),
    // Development-only: cycles every bubble shape and theme on the main screen for eyeballing.
    .executableTarget(name: "overlay-demo", dependencies: ["NarratorMac"]),
]
#endif

let package = Package(
    name: "LifeNarrator",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    dependencies: dependencies,
    targets: targets
)
