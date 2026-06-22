// swift-tools-version: 6.1
import PackageDescription

// Pathem — a high-performance, native macOS "superuser" file manager.
// See DESIGN.md for the architecture. The engine is deliberately split from
// the app by a plain-struct boundary and carries ZERO AppKit dependency, so it
// stays `swift test`-able against real temp dirs (CONVENTIONS: real-I/O tests).
let package = Package(
    name: "Pathem",
    platforms: [
        // Modern minimum; revisit if we lean fully into Liquid Glass (macOS 26)
        // or want to widen the audience. The dev machine is macOS 26.
        .macOS(.v15)
    ],
    targets: [
        // The engine: enumeration, watching, file ops, search. No AppKit.
        .target(name: "PathemEngine"),

        // The app: AppKit hot list + SwiftUI chrome. Depends on the engine.
        .executableTarget(
            name: "Pathem",
            dependencies: ["PathemEngine"]
        ),

        // Engine tests (Swift Testing).
        .testTarget(
            name: "PathemEngineTests",
            dependencies: ["PathemEngine"]
        ),
    ]
)
