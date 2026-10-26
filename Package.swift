// swift-tools-version: 5.9
// Native macOS viewer & exporter for single-fisheye 360° video (Kodak PixPro SP360 4K / Wideshoot). Look around, pick views, export reframed or 360 equirectangular MP4.
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
        .executable(name: "PortableChecks", targets: ["PortableChecks"]),
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
        .executableTarget(
            name: "PortableChecks",
            dependencies: ["ProjectionMath", "SpatialMedia"]
        ),
    ]
)
