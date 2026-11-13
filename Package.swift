// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WindowBack",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "WindowBackCore", path: "Sources/WindowBackCore"),
        .executableTarget(
            name: "WindowBack",
            dependencies: ["WindowBackCore"],
            path: "Sources/WindowBack"
        ),
        .executableTarget(
            name: "WindowBackSelfCheck",
            dependencies: ["WindowBackCore"],
            path: "Sources/WindowBackSelfCheck"
        )
    ]
)
