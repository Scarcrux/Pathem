import Foundation

/// Small JSON-config persistence used across the app: resolve the Application Support
/// directory, and load/save Codable values there. Reads that fail to decode move the bad
/// file aside (so one corrupt config never wedges the app); writes are atomic (temp + rename)
/// so a crash mid-write never truncates the existing file. Pure I/O, no actor state.
enum ConfigStore {
    /// `~/Library/Application Support/Pathem`, created if needed (nil if it can't be made).
    static func directory() -> URL? {
        let fm = FileManager.default
        #if DEBUG
            // Harness instrument: point every config file at a scratch directory so a screenshot or
            // smoke run can pin preferences (toolbar icon size, say) without touching the user's real
            // Application Support. Debug-only; never consulted in a release build.
            if let scratch = ProcessInfo.processInfo.environment["PATHEM_CONFIG_DIR"] {
                let dir = URL(fileURLWithPath: scratch, isDirectory: true)
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                return dir
            }
        #endif
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = base.appendingPathComponent("Pathem", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            NSLog("Pathem: cannot create Application Support directory: %@", String(describing: error))
            return nil  // callers stop rather than write into a nonexistent dir
        }
        return dir
    }

    /// The URL of a named config file under the Application Support directory.
    static func url(_ name: String) -> URL? {
        directory()?.appendingPathComponent(name)
    }

    static func load<T: Decodable>(_ type: T.Type, from url: URL?) -> T? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        if let decoded = try? JSONDecoder().decode(T.self, from: data) { return decoded }
        let fm = FileManager.default
        let aside = url.appendingPathExtension("corrupt")
        try? fm.removeItem(at: aside)
        try? fm.moveItem(at: url, to: aside)
        NSLog("Pathem: %@ was unreadable; moved aside to %@", url.lastPathComponent, aside.lastPathComponent)
        return nil
    }

    /// Encode and write atomically (temp file + rename), so a crash or power loss mid-write
    /// never truncates the existing file.
    static func save<T: Encodable>(_ value: T, to url: URL?) {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(value) { try? data.write(to: url, options: .atomic) }
    }
}
