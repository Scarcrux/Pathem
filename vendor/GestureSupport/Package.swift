// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GestureSupport",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "GestureSupport", targets: ["GestureSupport"]),
        .library(name: "GestureRecording", targets: ["GestureRecording"]),
    ],
    targets: [
        .target(name: "GestureSupport"),
        .target(name: "GestureRecording", dependencies: ["GestureSupport"]),
        .testTarget(
            name: "GestureSupportTests", dependencies: ["GestureSupport", "GestureRecording"]),
    ]
)
