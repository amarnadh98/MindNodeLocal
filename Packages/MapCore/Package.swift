// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "MapCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MapCore", targets: ["MapCore"])
    ],
    targets: [
        .target(
            name: "MapCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MapCoreTests",
            dependencies: ["MapCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
