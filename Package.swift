// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DotNetManager",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "DotNetManager", path: "Sources/DotNetManager")
    ]
)
