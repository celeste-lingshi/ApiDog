// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ApiDog",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "ApiDog"),
    ]
)
