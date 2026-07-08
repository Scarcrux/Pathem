import Foundation

/// A user-defined external command: a shell command template run on the current selection, with
/// placeholders expanded to the selected files. Persisted as external-commands.json and bindable
/// to a shortcut (each becomes a command in the registry). External tools only -- we run the
/// user's own command through /bin/sh; no embedded scripting language ships with the app.
/// Placeholder expansion is pure (so it's tested); `run` does the I/O.
public struct ExternalCommand: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    /// A shell command template. Placeholders: `%F` selected full paths, `%N` selected names,
    /// `%D` the current folder, `%P` the parent folder of the selection. `%%` is a literal `%`.
    public var command: String

    public init(id: String, name: String, command: String) {
        self.id = id
        self.name = name
        self.command = command
    }

    /// True when the template references the selection, so callers can require a non-empty one.
    public var usesSelection: Bool {
        command.contains("%F") || command.contains("%N") || command.contains("%P")
    }
}

/// Expands and runs `ExternalCommand`s.
public enum ExternalCommandRunner {
    public struct Output: Sendable {
        public let text: String
        public let exitCode: Int32
        public var succeeded: Bool { exitCode == 0 }
        public init(text: String, exitCode: Int32) {
            self.text = text
            self.exitCode = exitCode
        }
    }

    /// Single-quote a value for /bin/sh: wrap in `'...'`, escaping any embedded single quotes,
    /// so spaces and shell metacharacters in paths are inert.
    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Expand the placeholders in `template` for `files` in `directory`. Paths are shell-quoted;
    /// `%%` yields a literal `%`.
    public static func expand(_ template: String, files: [URL], directory: URL) -> String {
        let fullPaths = files.map { shellQuote($0.path) }.joined(separator: " ")
        let names = files.map { shellQuote($0.lastPathComponent) }.joined(separator: " ")
        let parent = shellQuote((files.first?.deletingLastPathComponent() ?? directory).path)
        let dir = shellQuote(directory.path)
        // Protect literal "%%" with a NUL sentinel so "%%F" stays "%F" rather than expanding.
        var result = template.replacingOccurrences(of: "%%", with: "\u{0}")
        result = result.replacingOccurrences(of: "%F", with: fullPaths)
        result = result.replacingOccurrences(of: "%N", with: names)
        result = result.replacingOccurrences(of: "%P", with: parent)
        result = result.replacingOccurrences(of: "%D", with: dir)
        return result.replacingOccurrences(of: "\u{0}", with: "%")
    }

    /// Run `command` through /bin/sh in `directory`, blocking until it exits (call this off the
    /// main thread). stdout and stderr are combined. Pass a `process` you retain to allow cancel
    /// (terminate it); otherwise a fresh one is used.
    @discardableResult
    public static func run(
        _ command: ExternalCommand, files: [URL], directory: URL, process: Process = Process()
    ) -> Output {
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", expand(command.command, files: files, directory: directory)]
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return Output(text: error.localizedDescription, exitCode: -1)
        }
        // Drain to EOF (which the process closes on exit) before waiting, so a large output
        // can't fill the pipe buffer and deadlock the child.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(text: String(data: data, encoding: .utf8) ?? "", exitCode: process.terminationStatus)
    }
}
