// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "CanvasKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CanvasKit", targets: ["CanvasKit"]),
        .library(name: "SceneExport", targets: ["SceneExport"]),
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
        // ADR-0012: pure (no AppKit) scene exporters — PDF, PNG/JPEG/HEIC,
        // SVG — over the `CanvasScene` the canvas already renders. A
        // separate target so the future Quick Look / Spotlight extensions
        // link the exporters without the view layer.
        .target(
            name: "SceneExport",
            dependencies: [
                .target(name: "CanvasKit"),
                .product(name: "MapCore", package: "MapCore"),
                .product(name: "MapRender", package: "MapRender"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CanvasKitTests",
            dependencies: ["CanvasKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SceneExportTests",
            dependencies: ["SceneExport"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
