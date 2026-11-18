// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "ArborUI",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ArborUI", targets: ["ArborUI"])
    ],
    dependencies: [
        .package(path: "../MapCore"),
        .package(path: "../MapLayout"),
        .package(path: "../MapRender"),
        .package(path: "../MapStudy"),
        .package(path: "../MapLibrary"),
    ],
    targets: [
        .target(
            name: "ArborUI",
            dependencies: [
                .product(name: "MapCore", package: "MapCore"),
                .product(name: "MapLayout", package: "MapLayout"),
                .product(name: "MapRender", package: "MapRender"),
                .product(name: "MapStudy", package: "MapStudy"),
                .product(name: "MapLibrary", package: "MapLibrary"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ArborUITests",
            dependencies: ["ArborUI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
