// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CoreBarsMonitor",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "CoreBarsMonitor",
            path: "Sources/CoreBarsMonitor"
        )
    ]
)
