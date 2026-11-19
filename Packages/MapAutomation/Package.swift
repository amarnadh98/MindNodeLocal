// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "MapAutomation",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MapAutomation", targets: ["MapAutomation"])
    ],
    dependencies: [
        .package(path: "../MapCore"),
        .package(path: "../MapIO"),
        .package(path: "../MapStudy"),
    ],
    targets: [
        .target(
            name: "MapAutomation",
            dependencies: [
                .product(name: "MapCore", package: "MapCore"),
                .product(name: "MapIO", package: "MapIO"),
                .product(name: "MapStudy", package: "MapStudy"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MapAutomationTests",
            dependencies: ["MapAutomation"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
