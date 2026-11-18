// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "MapRender",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MapRender", targets: ["MapRender"])
    ],
    dependencies: [
        .package(path: "../MapCore"),
        .package(path: "../MapLayout"),
    ],
    targets: [
        .target(
            name: "MapRender",
            dependencies: [
                .product(name: "MapCore", package: "MapCore"),
                .product(name: "MapLayout", package: "MapLayout"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MapRenderTests",
            dependencies: ["MapRender"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
