// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "KEFControl",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "KEFControl",
            path: "Sources/KEFControl"
        )
    ]
)
