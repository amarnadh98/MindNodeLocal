// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "MapStudy",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MapStudy", targets: ["MapStudy"])
    ],
    dependencies: [
        .package(path: "../MapCore")
    ],
    targets: [
        .target(
            name: "MapStudy",
            dependencies: [.product(name: "MapCore", package: "MapCore")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MapStudyTests",
            dependencies: ["MapStudy"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
