// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "MapIO",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MapIO", targets: ["MapIO"])
    ],
    dependencies: [
        .package(path: "../MapCore"),
        .package(path: "../MapRender"),
    ],
    targets: [
        .target(
            name: "MapIO",
            dependencies: [
                .product(name: "MapCore", package: "MapCore"),
                .product(name: "MapRender", package: "MapRender"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MapIOTests",
            dependencies: ["MapIO"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
