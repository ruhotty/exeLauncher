// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "exeLauncher",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "exeLauncher", targets: ["exeLauncher"])
    ],
    targets: [
        .executableTarget(name: "exeLauncher")
    ]
)
