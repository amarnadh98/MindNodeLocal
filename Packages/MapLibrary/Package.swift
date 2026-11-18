// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "MapLibrary",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MapLibrary", targets: ["MapLibrary"])
    ],
    dependencies: [
        .package(path: "../MapCore")
    ],
    targets: [
        .target(
            name: "MapLibrary",
            dependencies: [.product(name: "MapCore", package: "MapCore")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MapLibraryTests",
            dependencies: ["MapLibrary"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
