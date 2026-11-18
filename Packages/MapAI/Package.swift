// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "MapAI",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MapAI", targets: ["MapAI"])
    ],
    dependencies: [
        .package(path: "../MapCore")
    ],
    targets: [
        .target(
            name: "MapAI",
            dependencies: [.product(name: "MapCore", package: "MapCore")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MapAITests",
            dependencies: ["MapAI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
