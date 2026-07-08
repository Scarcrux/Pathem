import Foundation

/// Runs the user's macOS Shortcuts on files via the system `shortcuts` CLI (an external tool, so
/// within the hard rules -- no embedded scripting). Lists installed shortcuts and runs one over a
/// selection (once per file), combining output. All calls block, so run them off the main thread.
public enum ShortcutsRunner {
    private static let tool = URL(fileURLWithPath: "/usr/bin/shortcuts")
    public static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: tool.path) }

    /// Names of the installed shortcuts (empty if the tool is missing or none exist).
    public static func list() -> [String] {
        guard isAvailable else { return [] }
        return run(["list"]).text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Run `name` once per file (`shortcuts run <name> --input-path <file>`), combining output. With
    /// no files, runs the shortcut once with no input. A per-file header separates multiple runs.
    public static func runOnFiles(name: String, files: [URL]) -> ExternalCommandRunner.Output {
        guard isAvailable else {
            return ExternalCommandRunner.Output(text: "The Shortcuts tool isn’t available.", exitCode: -1)
        }
        let inputs: [URL?] = files.isEmpty ? [nil] : files
        var combined = ""
        var lastExit: Int32 = 0
        for file in inputs {
            var args = ["run", name]
            if let file { args += ["--input-path", file.path] }
            let output = run(args)
            if let file, inputs.count > 1 { combined += "== \(file.lastPathComponent) ==\n" }
            combined += output.text
            if !output.text.hasSuffix("\n") { combined += "\n" }
            if output.exitCode != 0 { lastExit = output.exitCode }
        }
        return ExternalCommandRunner.Output(text: combined, exitCode: lastExit)
    }

    private static func run(_ args: [String]) -> ExternalCommandRunner.Output {
        let process = Process()
        process.executableURL = tool
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return ExternalCommandRunner.Output(text: error.localizedDescription, exitCode: -1) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ExternalCommandRunner.Output(text: String(data: data, encoding: .utf8) ?? "", exitCode: process.terminationStatus)
    }
}
