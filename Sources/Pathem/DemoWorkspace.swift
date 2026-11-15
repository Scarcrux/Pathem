import AppKit
import PathemEngine

/// Builds a self-contained, privacy-safe sample workspace for screenshots, demos and the
/// first-run tour: believable folders and files (real project trees, documents with actual
/// pages, photographs drawn in code, varied sizes and dates, tags, a git working tree) under a
/// throwaway temp directory. Paired with the sidebar's demo mode, nothing on screen reveals
/// real file names, cloud accounts, hostnames, or the user's home path.
enum DemoWorkspace {
    struct Layout {
        let root: URL
        let leftStart: URL
        let rightStart: URL
        /// (display name, SF Symbol, folder) for the sidebar Favorites.
        let favorites: [(name: String, icon: String, url: URL)]
        /// Fake cloud entries (generic names, no account emails).
        let cloud: [(name: String, url: URL)]
        /// Fake volumes (no machine names).
        let volumes: [(name: String, url: URL)]
    }

    static func build(root: URL? = nil) -> Layout {
        let fm = FileManager.default
        let root =
            root ?? fm.temporaryDirectory.appendingPathComponent("Pathem-Demo", isDirectory: true)
        try? fm.removeItem(at: root)  // fresh each launch
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)

        let documents = buildDocuments(in: root)
        let projects = buildProjects(in: root)
        let photos = buildPhotos(in: root)
        let downloads = buildDownloads(in: root)
        let music = buildMusic(in: root)
        let desktop = buildDesktop(in: root)

        // Fake cloud + volumes point at demo folders, so clicking them stays in the sandbox.
        let icloud = folder("iCloud Drive", in: root, daysAgo: 1)
        text(
            "Shared Notes.md", in: icloud, "# Shared notes\n\n- Renew the domain\n- Book flights",
            daysAgo: 1)
        pdf(
            "Lease Renewal.pdf", in: icloud, title: "Lease Renewal", accent: 0x3a7bd5, pages: 3,
            daysAgo: 16)
        file("Family Budget.numbers", in: icloud, bytes: 412_000, daysAgo: 5)
        let dropbox = folder("Dropbox", in: root, daysAgo: 2)
        text(
            "Team Plan.md", in: dropbox, "# Q4 plan\n\n1. Ship 1.0\n2. Docs\n3. Launch", daysAgo: 2)
        file("Brand Assets.zip", in: dropbox, bytes: 86_400_000, daysAgo: 21)
        let macHD = folder("Macintosh HD", in: root, daysAgo: 3)
        for name in ["Applications", "Library", "System", "Users"] {
            _ = folder(name, in: macHD, daysAgo: 30)
        }
        let backups = folder("Time Machine", in: root, daysAgo: 0)
        for (index, name) in ["Latest", "2026-11-14-0915", "2026-11-13-0915"].enumerated() {
            _ = folder(name, in: backups, daysAgo: index)
        }

        return Layout(
            root: root, leftStart: projects, rightStart: photos,
            favorites: [
                ("Documents", "doc", documents), ("Desktop", "menubar.dock.rectangle", desktop),
                ("Downloads", "arrow.down.circle", downloads), ("Projects", "hammer", projects),
                ("Photos", "photo", photos), ("Music", "music.note", music),
            ],
            cloud: [("iCloud Drive", icloud), ("Dropbox", dropbox)],
            volumes: [("Macintosh HD", macHD), ("Time Machine", backups)])
    }

    // MARK: Folders

    private static func buildDocuments(in root: URL) -> URL {
        let documents = folder("Documents", in: root, daysAgo: 0)
        file("Q3 Board Deck.key", in: documents, bytes: 48_300_000, daysAgo: 2, tag: .red)
        file("Budget 2026.numbers", in: documents, bytes: 1_240_000, daysAgo: 6, tag: .green)
        pdf(
            "Offer Letter.pdf", in: documents, title: "Offer of Employment", accent: 0x2d6cdf,
            pages: 2, daysAgo: 44)
        pdf(
            "Quarterly Report.pdf", in: documents, title: "Quarterly Report", accent: 0x0f9d76,
            pages: 12, daysAgo: 3, tag: .orange)
        file("Résumé.pages", in: documents, bytes: 388_000, daysAgo: 71)
        text(
            "Meeting Notes.md", in: documents,
            "# Standup\n\n- Ship 1.0 this month\n- Polish transfers\n- Write the docs\n", daysAgo: 0
        )
        text(
            "Reading List.txt", in: documents,
            "The Design of Everyday Things\nA Philosophy of Software Design\n", daysAgo: 19)

        let travel = folder("Travel", in: documents, daysAgo: 9)
        pdf(
            "Itinerary Lisbon.pdf", in: travel, title: "Lisbon, 6 nights", accent: 0xe07a5f,
            pages: 4, daysAgo: 9, tag: .blue)
        file("Boarding Pass.pkpass", in: travel, bytes: 46_000, daysAgo: 9)
        pdf(
            "Hotel Confirmation.pdf", in: travel, title: "Booking Confirmation", accent: 0x8e6bd9,
            pages: 1, daysAgo: 12)
        touch(travel, daysAgo: 9)

        let taxes = folder("Taxes 2025", in: documents, daysAgo: 96)
        for (index, name) in [
            "W-2", "1099-INT", "1099-DIV", "Mortgage Interest", "Charitable Receipts",
            "Return (signed)",
        ].enumerated() {
            pdf(
                "\(name).pdf", in: taxes, title: name, accent: 0x5c6f8a, pages: 1 + index % 3,
                daysAgo: 96 + index * 4)
        }
        touch(taxes, daysAgo: 96)

        let contracts = folder("Contracts", in: documents, daysAgo: 27)
        pdf(
            "Master Services Agreement.pdf", in: contracts, title: "Master Services Agreement",
            accent: 0x33415c, pages: 18, daysAgo: 27, tag: .purple)
        pdf(
            "NDA (countersigned).pdf", in: contracts, title: "Mutual Non-Disclosure",
            accent: 0x33415c, pages: 5, daysAgo: 58)
        file("Statement of Work.docx", in: contracts, bytes: 164_000, daysAgo: 25)
        touch(contracts, daysAgo: 27)
        return documents
    }

    private static func buildProjects(in root: URL) -> URL {
        let projects = folder("Projects", in: root, daysAgo: 0)

        let aurora = folder("aurora-ios", in: projects, daysAgo: 0)
        text(
            "Package.swift", in: aurora,
            "// swift-tools-version: 6.0\nimport PackageDescription\n\nlet package = Package(name: \"Aurora\")\n",
            daysAgo: 14)
        text(
            "README.md", in: aurora,
            "# Aurora\n\nA weather app that shows tonight's aurora forecast.\n", daysAgo: 3)
        text(".gitignore", in: aurora, ".build/\nDerivedData/\n*.xcuserstate\n", daysAgo: 40)
        text("LICENSE", in: aurora, "MIT License\n", daysAgo: 40)
        let sources = folder("Sources", in: aurora, daysAgo: 0)
        let app = folder("Aurora", in: sources, daysAgo: 0)
        let swiftFiles: [(String, Int)] = [
            ("AuroraApp.swift", 11), ("ForecastView.swift", 0), ("ForecastModel.swift", 1),
            ("KpIndexClient.swift", 4), ("LocationProvider.swift", 8), ("MapOverlay.swift", 2),
            ("Notifications.swift", 19), ("Settings.swift", 23), ("Theme.swift", 30),
        ]
        for (name, days) in swiftFiles {
            text(
                name, in: app, "import SwiftUI\n\n// \(name)\nstruct Placeholder {}\n",
                daysAgo: days)
        }
        let tests = folder("Tests", in: aurora, daysAgo: 4)
        text(
            "ForecastModelTests.swift", in: tests,
            "import Testing\n\n@Test func parsesKpIndex() {}\n", daysAgo: 4)
        text(
            "KpIndexClientTests.swift", in: tests,
            "import Testing\n\n@Test func decodesFeed() {}\n", daysAgo: 6)
        let assets = folder("Assets", in: aurora, daysAgo: 5)
        photo(
            "App Icon.png", scene: "Tromsø Aurora", in: assets, width: 1024, height: 1024,
            daysAgo: 12)
        photo(
            "Launch Screen.png", scene: "Lofoten Dawn", in: assets, width: 1290, height: 2796,
            daysAgo: 5)
        file("Screens.sketch", in: assets, bytes: 24_600_000, daysAgo: 5, tag: .purple)
        file("Onboarding.fig", in: assets, bytes: 9_800_000, daysAgo: 17)
        makeGitWorkingTree(
            at: aurora, modified: ["Sources/Aurora/ForecastView.swift", "README.md"],
            untracked: "Sources/Aurora/MoonPhase.swift")

        let site = folder("portfolio-site", in: projects, daysAgo: 7)
        text(
            "index.html", in: site,
            "<!doctype html>\n<title>Portfolio</title>\n<h1>Selected work</h1>\n", daysAgo: 7)
        text(
            "styles.css", in: site,
            "body { font-family: -apple-system; margin: 4rem auto; max-width: 68ch; }\n", daysAgo: 8
        )
        text("app.js", in: site, "document.documentElement.classList.add('js')\n", daysAgo: 21)
        text(
            "package.json", in: site,
            "{\n  \"name\": \"portfolio-site\",\n  \"private\": true\n}\n", daysAgo: 33)
        let images = folder("images", in: site, daysAgo: 8)
        photo("hero.jpg", scene: "Big Sur Coast", in: images, daysAgo: 8)
        photo("case-study-1.jpg", scene: "Kyoto Night", in: images, daysAgo: 15)
        photo("case-study-2.jpg", scene: "Sahara Dunes", in: images, daysAgo: 15)
        touch(site, daysAgo: 7)

        let ml = folder("ml-experiments", in: projects, daysAgo: 1)
        text(
            "train.py", in: ml,
            "import torch\n\ndef main():\n    ...\n\nif __name__ == \"__main__\":\n    main()\n",
            daysAgo: 1, tag: .yellow)
        text("eval.ipynb", in: ml, "{\"cells\": [], \"nbformat\": 4}\n", daysAgo: 2)
        text("requirements.txt", in: ml, "torch\nnumpy\npandas\npyarrow\n", daysAgo: 26)
        text("config.yaml", in: ml, "model: vit-small\nbatch_size: 256\nepochs: 24\n", daysAgo: 1)
        let data = folder("data", in: ml, daysAgo: 26)
        file("train.parquet", in: data, bytes: 1_840_000_000, daysAgo: 26)
        file("val.parquet", in: data, bytes: 212_000_000, daysAgo: 26)
        file("labels.csv", in: data, bytes: 4_300_000, daysAgo: 26)
        let checkpoints = folder("checkpoints", in: ml, daysAgo: 1)
        for (epoch, days) in [(6, 4), (12, 3), (18, 2), (24, 1)] {
            file(
                String(format: "epoch-%02d.pt", epoch), in: checkpoints, bytes: 438_000_000,
                daysAgo: days)
        }
        touch(ml, daysAgo: 1)

        let api = folder("api-server", in: projects, daysAgo: 10)
        text("main.go", in: api, "package main\n\nfunc main() {}\n", daysAgo: 10)
        text("go.mod", in: api, "module example.com/api\n\ngo 1.24\n", daysAgo: 52)
        text(
            "Dockerfile", in: api,
            "FROM gcr.io/distroless/static\nCOPY api /api\nENTRYPOINT [\"/api\"]\n", daysAgo: 38)
        text(
            "openapi.yaml", in: api, "openapi: 3.1.0\ninfo:\n  title: API\n  version: 1.4.0\n",
            daysAgo: 13)
        let bin = folder("bin", in: api, daysAgo: 10)
        file("api", in: bin, bytes: 14_700_000, daysAgo: 10)
        let handlers = folder("handlers", in: api, daysAgo: 10)
        for name in ["auth.go", "billing.go", "health.go", "users.go", "webhooks.go"] {
            text(name, in: handlers, "package handlers\n", daysAgo: 10 + name.count)
        }
        touch(api, daysAgo: 10)

        let design = folder("design-system", in: projects, daysAgo: 18)
        file("Components.fig", in: design, bytes: 61_000_000, daysAgo: 18, tag: .purple)
        file("Icons.sketch", in: design, bytes: 7_400_000, daysAgo: 35)
        text("tokens.json", in: design, "{\n  \"color.accent\": \"#2d6cdf\"\n}\n", daysAgo: 18)
        pdf(
            "Brand Guidelines.pdf", in: design, title: "Brand Guidelines", accent: 0xd9486e,
            pages: 24, daysAgo: 64)
        touch(design, daysAgo: 18)

        let notes = folder("field-notes", in: projects, daysAgo: 4)
        for (name, days) in [
            ("2026-11 Lisbon.md", 4), ("2026-09 Dolomites.md", 62), ("2026-06 Lofoten.md", 150),
        ] {
            text(name, in: notes, "# \(name.dropLast(3))\n\nNotes from the trip.\n", daysAgo: days)
        }
        photo("lisbon-sketch.jpg", scene: "Santorini Dusk", in: notes, variant: "notes", daysAgo: 4)
        touch(notes, daysAgo: 4)

        let archive = folder("Archive", in: projects, daysAgo: 210)
        file("old-blog-2023.zip", in: archive, bytes: 412_000_000, daysAgo: 420)
        file("thesis-backup.tar.gz", in: archive, bytes: 1_260_000_000, daysAgo: 610)
        touch(archive, daysAgo: 210)

        text(
            "TODO.md", in: projects,
            "- [ ] Ship aurora 1.2\n- [ ] Portfolio case study\n- [x] Rotate API keys\n",
            daysAgo: 0, tag: .red)
        file("Roadmap.key", in: projects, bytes: 18_900_000, daysAgo: 11)
        touch(aurora, daysAgo: 0)
        return projects
    }

    private static func buildPhotos(in root: URL) -> URL {
        let photos = folder("Photos", in: root, daysAgo: 2)
        let shots: [(String, String, Int, FileTag.Color?)] = [
            ("Lofoten Dawn.jpg", "Lofoten Dawn", 150, .orange),
            ("Reine Harbour.jpg", "Patagonia", 151, nil),
            ("Dolomites Ridge.jpg", "Dolomites", 62, .green),
            ("Lake Louise.jpg", "Lake Louise", 240, .blue),
            ("Big Sur Coast.jpg", "Big Sur Coast", 201, nil),
            ("Tromsø Aurora.jpg", "Tromsø Aurora", 320, .purple),
            ("Sahara Dunes.jpg", "Sahara Dunes", 402, nil),
            ("Namib Sunrise.jpg", "Namib Sunrise", 404, .orange),
            ("Kyoto Night.jpg", "Kyoto Night", 512, nil),
            ("Tokyo Skyline.jpg", "Tokyo Skyline", 514, .red),
            ("Santorini Dusk.jpg", "Santorini Dusk", 31, nil),
            ("Redwoods Fog.jpg", "Redwoods Fog", 88, .green),
        ]
        for (name, scene, days, tag) in shots {
            photo(name, scene: scene, in: photos, daysAgo: days, tag: tag)
        }
        let lisbon = folder("2026-11 Lisbon", in: photos, daysAgo: 4)
        for (index, scene) in [
            "Santorini Dusk", "Big Sur Coast", "Tokyo Skyline", "Namib Sunrise", "Kyoto Night",
        ].enumerated() {
            photo(
                String(format: "IMG_%04d.jpg", 4120 + index * 3), scene: scene, in: lisbon,
                variant: "lisbon\(index)", daysAgo: 4 + index % 3)
        }
        touch(lisbon, daysAgo: 4)
        touch(photos, daysAgo: 2)
        return photos
    }

    private static func buildDownloads(in root: URL) -> URL {
        let downloads = folder("Downloads", in: root, daysAgo: 0)
        file("Pathem-1.0.dmg", in: downloads, bytes: 18_600_000, daysAgo: 0)
        file("ubuntu-26.04-desktop-arm64.iso", in: downloads, bytes: 5_120_000_000, daysAgo: 1)
        file("dataset.zip", in: downloads, bytes: 246_000_000, daysAgo: 4)
        file("Screen Recording 2026-11-02.mov", in: downloads, bytes: 184_000_000, daysAgo: 13)
        pdf(
            "Invoice 1042.pdf", in: downloads, title: "Invoice 1042", accent: 0x2d6cdf, pages: 1,
            daysAgo: 6)
        pdf(
            "Statement October.pdf", in: downloads, title: "Account Statement", accent: 0x0f9d76,
            pages: 3, daysAgo: 10)
        file("Inter-4.1.zip", in: downloads, bytes: 31_400_000, daysAgo: 17)
        file("Xcode_27.1.xip", in: downloads, bytes: 3_420_000_000, daysAgo: 22)
        file("podcast-episode-88.mp3", in: downloads, bytes: 71_200_000, daysAgo: 3)
        photo("wallpaper-5k.jpg", scene: "Dolomites", in: downloads, variant: "wall", daysAgo: 8)
        return downloads
    }

    private static func buildMusic(in root: URL) -> URL {
        let music = folder("Music", in: root, daysAgo: 30)
        let albums: [(String, String, [String])] = [
            (
                "Nightscapes", "Tromsø Aurora",
                ["Aurora", "Meridian", "Low Tide", "Northern Line", "Halogen", "Afterglow"]
            ),
            (
                "Field Recordings", "Redwoods Fog",
                ["Morning Rain", "Canopy", "River Stones", "Dusk Chorus"]
            ),
        ]
        for (album, scene, tracks) in albums {
            let dir = folder(album, in: music, daysAgo: 30)
            for (index, track) in tracks.enumerated() {
                file(
                    String(format: "%02d %@.flac", index + 1, track), in: dir,
                    bytes: 31_000_000 + index * 2_700_000, daysAgo: 30)
            }
            photo(
                "cover.jpg", scene: scene, in: dir, variant: album, width: 1400, height: 1400,
                daysAgo: 30)
            touch(dir, daysAgo: 30)
        }
        touch(music, daysAgo: 30)
        return music
    }

    private static func buildDesktop(in root: URL) -> URL {
        let desktop = folder("Desktop", in: root, daysAgo: 0)
        photo(
            "Screenshot 2026-11-14 at 9.41.12 AM.png", scene: "Santorini Dusk", in: desktop,
            variant: "shot", width: 1728, height: 1117, daysAgo: 1)
        text("Scratch.md", in: desktop, "- call the bank\n- renew passport\n", daysAgo: 0)
        file("Design Review.key", in: desktop, bytes: 22_100_000, daysAgo: 2, tag: .blue)
        return desktop
    }

    // MARK: Builders

    private static func folder(_ name: String, in parent: URL, daysAgo: Int) -> URL {
        let url = parent.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        touch(url, daysAgo: daysAgo)
        return url
    }

    private static func text(
        _ name: String, in folder: URL, _ content: String, daysAgo: Int,
        tag: FileTag.Color? = nil
    ) {
        let url = folder.appendingPathComponent(name)
        // Pad to a believable size for its kind: a real source or notes file is a few
        // kilobytes, and a column of "42 bytes" gives a staged folder away.
        var data = Data(content.utf8)
        var hash: UInt64 = 5381
        for byte in name.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        let target = 900 + Int(hash % 14_000)
        let filler = Data((content.hasSuffix("\n") ? content : content + "\n").utf8)
        while data.count < target, !filler.isEmpty { data.append(filler) }
        try? data.write(to: url)
        finish(url, daysAgo: daysAgo, tag: tag)
    }

    /// A sparse file of the given logical size (cheap on disk) so the size column looks real.
    private static func file(
        _ name: String, in folder: URL, bytes: Int, daysAgo: Int, tag: FileTag.Color? = nil
    ) {
        let url = folder.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: url) {
            try? handle.truncate(atOffset: UInt64(bytes))
            try? handle.close()
        }
        finish(url, daysAgo: daysAgo, tag: tag)
    }

    private static func photo(
        _ name: String, scene: String, in folder: URL, variant: String = "", width: Int = 2000,
        height: Int = 1250, daysAgo: Int, tag: FileTag.Color? = nil
    ) {
        let url = folder.appendingPathComponent(name)
        let asPNG = name.lowercased().hasSuffix(".png")
        if let data = DemoArt.encoded(
            scene, variant: variant, width: width, height: height, png: asPNG)
        {
            try? data.write(to: url)
        }
        finish(url, daysAgo: daysAgo, tag: tag)
    }

    /// A real, readable PDF (letterhead, heading, body lines, a small chart) so document
    /// thumbnails and Quick Look show a page instead of a blank icon.
    private static func pdf(
        _ name: String, in folder: URL, title: String, accent: UInt32, pages: Int, daysAgo: Int,
        tag: FileTag.Color? = nil
    ) {
        let url = folder.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        if let ctx = CGContext(url as CFURL, mediaBox: &box, nil) {
            let ink = DemoArt.c(accent)
            var seed = UInt64(truncatingIfNeeded: name.hashValue)
            func rand() -> CGFloat {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return CGFloat((seed >> 33) & 0xFFFF) / CGFloat(0xFFFF)
            }
            for page in 0..<max(pages, 1) {
                ctx.beginPDFPage(nil)
                let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = ns
                NSColor.white.setFill()
                box.fill()
                ink.setFill()
                NSRect(x: 0, y: 742, width: 612, height: 50).fill()
                var y: CGFloat = 690
                if page == 0 {
                    (title as NSString).draw(
                        at: NSPoint(x: 54, y: 668),
                        withAttributes: [
                            .font: NSFont.systemFont(ofSize: 26, weight: .bold),
                            .foregroundColor: NSColor(white: 0.12, alpha: 1),
                        ])
                    y = 640
                    // A small bar chart.
                    for bar in 0..<7 {
                        let height = 30 + 90 * rand()
                        ink.withAlphaComponent(0.35 + 0.08 * CGFloat(bar)).setFill()
                        NSRect(x: 360 + CGFloat(bar) * 28, y: 520, width: 20, height: height).fill()
                    }
                }
                NSColor(white: 0.72, alpha: 1).setFill()
                var line = 0
                while y > 70 {
                    let inChartArea = page == 0 && y > 500 && y < 640
                    let full: CGFloat = inChartArea ? 270 : 504
                    let width =
                        line % 6 == 5 ? full * (0.3 + 0.4 * rand()) : full * (0.86 + 0.14 * rand())
                    NSRect(x: 54, y: y, width: width, height: 5).fill()
                    y -= line % 6 == 5 ? 26 : 13
                    line += 1
                }
                NSGraphicsContext.restoreGraphicsState()
                ctx.endPDFPage()
            }
            ctx.closePDF()
        }
        finish(url, daysAgo: daysAgo, tag: tag)
    }

    /// Turn a demo project into a real git working tree with a clean history plus a couple of
    /// local changes, so the status badges have something true to show. Skipped when no real
    /// git is installed (the /usr/bin/git shim would otherwise offer to install developer tools).
    private static func makeGitWorkingTree(at repo: URL, modified: [String], untracked: String) {
        let fm = FileManager.default
        let candidates = [
            "/Library/Developer/CommandLineTools/usr/bin/git",
            "/Applications/Xcode.app/Contents/Developer/usr/bin/git", "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
        ]
        guard let git = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) else { return }
        func run(_ arguments: [String]) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: git)
            process.arguments =
                [
                    "-C", repo.path, "-c", "user.name=Demo", "-c",
                    "user.email=demo@example.invalid",
                    "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
                ] + arguments
            process.environment = [
                "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
                "GIT_AUTHOR_DATE": "2026-10-01T09:00:00",
                "GIT_COMMITTER_DATE": "2026-10-01T09:00:00",
                "PATH": "/usr/bin:/bin",
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
        run(["init", "-q", "-b", "main"])
        run(["add", "-A"])
        run(["commit", "-q", "-m", "Initial import"])
        for relative in modified {
            let url = repo.appendingPathComponent(relative)
            let date = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data("\n// work in progress\n".utf8))
                try? handle.close()
            }
            if let date { try? fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path) }
        }
        let extra = repo.appendingPathComponent(untracked)
        try? Data("import Foundation\n\nenum MoonPhase {}\n".utf8).write(to: extra)
        touch(extra, daysAgo: 0)
    }

    private static func finish(_ url: URL, daysAgo: Int, tag: FileTag.Color?) {
        if let tag { try? FileTags.setTags([FileTag(name: tag.label, color: tag)], on: url) }
        touch(url, daysAgo: daysAgo)
    }

    /// Spread the timestamps through the day as well, so a column of dates is not one repeated
    /// minute (which is what gave earlier screenshots away as staged).
    private static func touch(_ url: URL, daysAgo: Int) {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in url.lastPathComponent.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        let secondsIntoDay = Double(hash % 36_000) + 8 * 3600  // 08:00 to 18:00
        let midnight = Calendar.current.startOfDay(for: Date())
        var date = midnight.addingTimeInterval(-Double(daysAgo) * 86_400 + secondsIntoDay)
        if date > Date() { date = Date().addingTimeInterval(-Double(hash % 3000) - 120) }
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}
