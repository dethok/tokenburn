// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TokenBurn",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "TokenBurn",
            path: "Sources/ClaudeUsage",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
