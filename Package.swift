// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ThreeSixtyView",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "ProjectionMath", targets: ["ProjectionMath"]),
        .library(name: "SpatialMedia", targets: ["SpatialMedia"]),
        .library(name: "ThreeSixtyEngine", targets: ["ThreeSixtyEngine"]),
        .executable(name: "ThreeSixtyView", targets: ["ThreeSixtyView"]),
    ],
    targets: [
        .target(name: "ProjectionMath"),
        .target(name: "SpatialMedia"),
        .target(
            name: "ThreeSixtyEngine",
            dependencies: ["ProjectionMath", "SpatialMedia"]
        ),
        .executableTarget(
            name: "ThreeSixtyView",
            dependencies: ["ProjectionMath", "SpatialMedia", "ThreeSixtyEngine"]
        ),
    ]
)
