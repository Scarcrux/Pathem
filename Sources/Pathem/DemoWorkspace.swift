import AppKit

/// Builds a self-contained, privacy-safe fake workspace for screenshots and demos: realistic
/// folders and files (with believable sizes and dates, plus real thumbnails for images) under a
/// throwaway temp directory. Paired with the sidebar's demo mode, nothing on screen reveals real
/// file names, cloud accounts, hostnames, or the user's home path.
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

    static func build() -> Layout {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Pathem-Demo", isDirectory: true)
        try? fm.removeItem(at: root)  // fresh each launch
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)

        let documents = folder("Documents", in: root)
        text("Welcome to Pathem.md", in: documents, "# Pathem\n\nA fast, native macOS file manager.")
        file("Quarterly Report.pdf", in: documents, bytes: 2_400_000, daysAgo: 3)
        file("Budget.numbers", in: documents, bytes: 340_000, daysAgo: 12)
        file("Contract.pages", in: documents, bytes: 88_000, daysAgo: 40)
        text("Meeting Notes.txt", in: documents, "Standup: ship v1, polish transfers, write docs.")

        let projects = folder("Projects", in: root)
        let pathem = folder("pathem", in: projects)
        text("README.md", in: pathem, "# pathem\nDirectory-Opus-class Finder replacement.")
        text("main.swift", in: pathem, "@main enum App { static func main() { print(\"hi\") } }")
        file("logo.sketch", in: pathem, bytes: 1_800_000, daysAgo: 8)
        let site = folder("portfolio-site", in: projects)
        text("index.html", in: site, "<!doctype html><title>Portfolio</title>")
        text("styles.css", in: site, "body { font-family: -apple-system; }")
        _ = folder("ml-experiments", in: projects)

        let photos = folder("Photos", in: root)
        png("Sunset.png", in: photos, color: .systemOrange, daysAgo: 2)
        png("Mountains.png", in: photos, color: .systemTeal, daysAgo: 5)
        png("Coastline.png", in: photos, color: .systemBlue, daysAgo: 9)
        png("Forest.png", in: photos, color: .systemGreen, daysAgo: 14)
        png("City.png", in: photos, color: .systemPurple, daysAgo: 20)
        png("Desert.png", in: photos, color: .systemYellow, daysAgo: 27)

        let downloads = folder("Downloads", in: root)
        file("Pathem-1.0.dmg", in: downloads, bytes: 18_600_000, daysAgo: 1)
        file("dataset.zip", in: downloads, bytes: 246_000_000, daysAgo: 4)
        file("demo-render.mp4", in: downloads, bytes: 92_000_000, daysAgo: 6)
        file("invoice.pdf", in: downloads, bytes: 120_000, daysAgo: 10)

        let music = folder("Music", in: root)
        let album = folder("Nightscapes", in: music)
        file("01 Aurora.flac", in: album, bytes: 41_000_000, daysAgo: 30)
        file("02 Meridian.flac", in: album, bytes: 38_000_000, daysAgo: 30)

        let desktop = folder("Desktop", in: root)
        png("Screenshot.png", in: desktop, color: .systemGray, daysAgo: 0)

        // Fake cloud + volumes point at demo folders, so clicking them stays in the sandbox.
        let icloud = folder("iCloud Drive", in: root)
        text("shared-notes.txt", in: icloud, "synced")
        let dropbox = folder("Dropbox", in: root)
        text("team-plan.md", in: dropbox, "# Plan")
        let macHD = folder("Macintosh HD", in: root)
        _ = folder("Applications", in: macHD)
        let backups = folder("Time Machine", in: root)
        _ = folder("Latest", in: backups)

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

    // MARK: Builders

    private static func folder(_ name: String, in parent: URL) -> URL {
        let url = parent.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func text(_ name: String, in folder: URL, _ content: String) {
        let url = folder.appendingPathComponent(name)
        try? content.data(using: .utf8)?.write(to: url)
        touch(url, daysAgo: 1)
    }

    /// A sparse file of the given logical size (cheap on disk) so the size column looks real.
    private static func file(_ name: String, in folder: URL, bytes: Int, daysAgo: Int) {
        let url = folder.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: url) {
            try? handle.truncate(atOffset: UInt64(bytes))
            try? handle.close()
        }
        touch(url, daysAgo: daysAgo)
    }

    private static func png(_ name: String, in folder: URL, color: NSColor, daysAgo: Int) {
        let url = folder.appendingPathComponent(name)
        let side = 512
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        image.unlockFocus()
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
            let data = rep.representation(using: .png, properties: [:])
        {
            try? data.write(to: url)
        }
        touch(url, daysAgo: daysAgo)
    }

    private static func touch(_ url: URL, daysAgo: Int) {
        let date = Date().addingTimeInterval(-Double(daysAgo) * 86_400)
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}
