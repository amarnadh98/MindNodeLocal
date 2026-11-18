// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "CanvasKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CanvasKit", targets: ["CanvasKit"])
    ],
    dependencies: [
        .package(path: "../MapCore"),
        .package(path: "../MapLayout"),
        .package(path: "../MapRender"),
    ],
    targets: [
        .target(
            name: "CanvasKit",
            dependencies: [
                .product(name: "MapCore", package: "MapCore"),
                .product(name: "MapLayout", package: "MapLayout"),
                .product(name: "MapRender", package: "MapRender"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CanvasKitTests",
            dependencies: ["CanvasKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
