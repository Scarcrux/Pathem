// swift-tools-version: 6.1
import PackageDescription

// Pathem — a high-performance, native macOS "superuser" file manager.
// See DESIGN.md for the architecture. The engine is deliberately split from
// the app by a plain-struct boundary and carries ZERO AppKit dependency, so it
// stays `swift test`-able against real temp dirs (CONVENTIONS: real-I/O tests).
let package = Package(
    name: "Pathem",
    defaultLocalization: "en",
    platforms: [
        // Modern minimum; revisit if we lean fully into Liquid Glass (macOS 26)
        // or want to widen the audience. The dev machine is macOS 26.
        .macOS(.v15)
    ],
    dependencies: [
        // SwiftTerm (MIT): a real VT/xterm terminal emulator in pure Swift. Used
        // only by the optional PathemTerminal module so the rest of the app and
        // the engine stay dependency-free. Compiled in (not a loaded bundle), so
        // it does not affect our clean Hardened Runtime stance.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.13.0"),
        // Sparkle (MIT): the auto-update framework. Used by the app for the
        // notarized direct-download build's update feed (DESIGN.md). A linked
        // framework, embedded and signed by scripts/package.sh.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.3"),
    ],
    targets: [
        // The engine: enumeration, watching, file ops, search. No AppKit.
        .target(name: "PathemEngine"),

        // Optional terminal module: an embedded shell pane that follows the
        // active folder. Isolates the SwiftTerm dependency from everything else;
        // remove this target (and the app's dependency on it) to drop the
        // feature and the dependency entirely.
        .target(
            name: "PathemTerminal",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")]
        ),

        // The app: AppKit hot list + SwiftUI chrome. Depends on the engine and
        // the optional terminal module.
        .executableTarget(
            name: "Pathem",
            dependencies: [
                "PathemEngine", "PathemTerminal",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            resources: [.process("Resources")]  // localized .strings (en, es, …)
        ),

        // Engine tests (Swift Testing).
        .testTarget(
            name: "PathemEngineTests",
            dependencies: ["PathemEngine"]
        ),

        // Out-of-process helper that browses a paired iOS device over AFC (usbmux +
        // lockdown + TLS + AFC). The app invokes this binary so untrusted device parsing
        // stays out of the Full-Disk-Access process. Bundled + signed by package.sh.
        .executableTarget(name: "pathem-afc", dependencies: ["PathemEngine"]),

        // Reference out-of-process Swift extension helper. Not shipped in the app; it is the
        // canonical example an extension author copies, and it exercises the ExtensionHost
        // wire protocol (line-delimited JSON over stdio) so the seam can't rot.
        .executableTarget(name: "pathem-ext-example", dependencies: ["PathemEngine"]),
    ]
)
