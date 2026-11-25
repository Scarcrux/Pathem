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
        .package(path: "vendor/GestureSupport"),
        // SwiftTerm (MIT): a real VT/xterm terminal emulator in pure Swift. Used
        // only by the optional PathemTerminal module so the rest of the app and
        // the engine stay dependency-free. Compiled in (not a loaded bundle), so
        // it does not affect our clean Hardened Runtime stance.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.13.0"),
        // Sparkle (MIT): the auto-update framework. Used by the app for the
        // notarized direct-download build's update feed (DESIGN.md). A linked
        // framework, embedded and signed by scripts/package.sh.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.3"),
    ],
    targets: [
        .target(name: "PathemExtensionRuntime"),
        .executableTarget(name: "pathem-ext-launch"),
        // The engine: enumeration, watching, file ops, search. No AppKit.
        .target(
            name: "PathemEngine",
            dependencies: [
                "PathemExtensionRuntime",
                .product(name: "GestureSupport", package: "GestureSupport"),
            ]),

        // AppRelaunch: the shared stale-build watcher (notices when a newer bundle is installed
        // under the running process and offers a relaunch). Vendored in-tree as a local target
        // rather than a remote package so a lone checkout -- CI, a clean clone, the public clone --
        // builds with zero credentials. The upstream (shared with the commandem menubar) stays the
        // source of truth; re-vendor from there when it changes. See Sources/AppRelaunch for the
        // provenance header. Pinned to the Swift 5 language mode it was written in (the upstream
        // package is swift-tools 5.9) so the vendored copy compiles unedited under Pathem's 6.1
        // tools; re-vendoring stays a pure file copy.
        .target(name: "AppRelaunch", swiftSettings: [.swiftLanguageMode(.v5)]),

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
                "PathemEngine", "PathemTerminal", "TorrentKit", "AppRelaunch",
                .product(name: "GestureRecording", package: "GestureSupport"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            resources: [.process("Resources")]  // localized .strings (en, es, …)
        ),

        // Engine tests (Swift Testing).
        .testTarget(
            name: "PathemEngineTests",
            dependencies: ["PathemEngine"],
            exclude: ["placeholder"]
        ),

        // Shared package conformance/native recorder checks run in the normal gate.
        .testTarget(
            name: "GestureSupportTests",
            dependencies: [
                .product(name: "GestureSupport", package: "GestureSupport"),
                .product(name: "GestureRecording", package: "GestureSupport"),
            ],
            path: "vendor/GestureSupport/Tests/GestureSupportTests"),

        // AppRelaunch tests (vendored alongside the target).
        .testTarget(
            name: "AppRelaunchTests", dependencies: ["AppRelaunch"],
            swiftSettings: [.swiftLanguageMode(.v5)]),

        // Out-of-process helper that browses a paired iOS device over AFC (usbmux +
        // lockdown + TLS + AFC). The app invokes this binary so untrusted device parsing
        // stays out of the Full-Disk-Access process. Bundled + signed by package.sh.
        .executableTarget(name: "pathem-afc", dependencies: ["PathemEngine"]),

        // The `pathem` CLI: the stable reveal/open seam for Finder-handoff integrations. Resolves a
        // path and asks the app to act on it via the pathem:// URL scheme. Bundled by package.sh as
        // `pathem-cli` (a `pathem` on-PATH symlink can't sit in MacOS/ next to `Pathem`).
        .executableTarget(name: "pathem-cli", dependencies: ["PathemEngine"]),

        .executableTarget(name: "pathem-theme-catalog", dependencies: ["PathemEngine"]),

        // Reference out-of-process Swift extension helper. Not shipped in the app; it is the
        // canonical example an extension author copies, and it exercises the ExtensionHost
        // wire protocol (line-delimited JSON over stdio) so the seam can't rot.
        .executableTarget(name: "pathem-ext-example", dependencies: ["PathemEngine"]),

        // Opt-in environmental verifier. Kept out of the app bundle: it exercises real host
        // boundaries (secondary volumes, local protocol servers, Spotlight, routers and public
        // DHT) and reports PASS/SKIP/FAIL without turning absent hardware into a green test.
        .executableTarget(
            name: "pathem-env-probe", dependencies: ["PathemEngine", "TorrentKit"]),

        // TorrentKit: our native Swift BitTorrent engine -- bencode + .torrent metadata,
        // HTTP tracker client, peer wire protocol, piece manager with SHA-1 verification,
        // file layout + sparse storage, peer connections (Network.framework), and the
        // per-torrent download session. Foundation + Network only, no AppKit; the pure layers
        // are fully unit-tested.
        .target(name: "TorrentKit"),

        // pathem-torrentd: the long-running torrent daemon. The Pathem app spawns it and drives
        // the TorrentEngine over a line-delimited JSON control protocol (stdin/stdout), polling
        // status for the Torrents panel. Downloads persist and resume across restarts.
        .executableTarget(name: "pathem-torrentd", dependencies: ["TorrentKit"]),

        // TorrentKit tests (bencode + .torrent parsing against real fixtures).
        .testTarget(name: "TorrentKitTests", dependencies: ["TorrentKit"]),
    ]
)
