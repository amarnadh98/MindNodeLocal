// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "MapLayout",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MapLayout", targets: ["MapLayout"])
    ],
    dependencies: [
        .package(path: "../MapCore")
    ],
    targets: [
        .target(
            name: "MapLayout",
            dependencies: [.product(name: "MapCore", package: "MapCore")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MapLayoutTests",
            dependencies: ["MapLayout"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
