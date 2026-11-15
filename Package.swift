// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "exeLauncher",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "exeLauncher", targets: ["exeLauncher"])
    ],
    targets: [
        .executableTarget(name: "exeLauncher")
    ]
)
