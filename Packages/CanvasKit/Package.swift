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
        // M6: the RevealEngine's `RevealState` is the one vocabulary the
        // canvas overlay, presentation builds and study recall read
        // (SPEC §10). CanvasKit → MapStudy → MapCore; no cycle.
        .package(path: "../MapStudy"),
        // M3 (F-CNT-5, ADR-0027): LaTeX math rendering. Runtime
        // dependency 2 of 8 (SPEC §11.1); linked into CanvasKit only —
        // the pure SceneExport target never imports it.
        .package(url: "https://github.com/mgriebling/SwiftMath", from: "1.7.0"),
    ],
    targets: [
        .target(
            name: "CanvasKit",
            dependencies: [
                .product(name: "MapCore", package: "MapCore"),
                .product(name: "MapLayout", package: "MapLayout"),
                .product(name: "MapRender", package: "MapRender"),
                .product(name: "MapStudy", package: "MapStudy"),
                .product(name: "SwiftMath", package: "SwiftMath"),
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
