// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ShellShot",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "ShellShot", path: "Sources/ShellShot")
    ]
)
