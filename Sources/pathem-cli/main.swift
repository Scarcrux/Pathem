import Foundation
import PathemEngine

// The `pathem` command-line tool. It resolves paths to absolute and hands them to the running (or
// launched) app over the pathem:// URL scheme -- the one stable seam every editor/Finder-handoff
// integration targets, so their config never has to know the launch details. Argument parsing,
// the open-vs-reveal choice and git-status parsing live in PathemEngine (PathemCLI); this file
// only wires them to the filesystem, `git` and Launch Services.

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func isDirectory(_ path: String) -> Bool {
    var flag: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &flag) && flag.boolValue
}

/// Print the URL (`--print`) or hand it to Launch Services, then exit.
func deliver(verb: PathemURLContract.Verb, path: String, printOnly: Bool) -> Never {
    guard let url = PathemURLContract.url(verb: verb, path: path) else {
        fail("pathem: could not form a URL for \(path)", 1)
    }
    if printOnly {
        print(url.absoluteString)
        exit(0)
    }
    // `open <url>` routes the pathem:// URL to Pathem (launching it if needed) via LaunchServices.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [url.absoluteString]
    do {
        try process.run()
    } catch {
        fail("pathem: could not reach Pathem: \(error.localizedDescription)", 1)
    }
    process.waitUntilExit()
    exit(process.terminationStatus)
}

func git(_ arguments: [String], in directory: String) -> (status: Int32, output: Data) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", directory] + arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return (127, Data()) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, data)
}

let cwd = FileManager.default.currentDirectoryPath
guard let invocation = PathemCLI.parse(Array(CommandLine.arguments.dropFirst())) else {
    fail(PathemCLI.usage, 2)
}

switch invocation {
case .help:
    print(PathemCLI.usage)
    exit(0)

case .act(let requestedVerb, let raw, let printOnly):
    let path = PathemCLI.resolve(raw, against: cwd)
    guard FileManager.default.fileExists(atPath: path) else {
        fail("pathem: no such file or directory: \(raw)", 1)
    }
    deliver(
        verb: requestedVerb ?? PathemCLI.automaticVerb(isDirectory: isDirectory(path)),
        path: path, printOnly: printOnly)

case .changed(let directory, let printOnly):
    let start = PathemCLI.resolve(directory ?? ".", against: cwd)
    guard isDirectory(start) else { fail("pathem: no such directory: \(directory ?? start)", 1) }
    let top = git(["rev-parse", "--show-toplevel"], in: start)
    guard top.status == 0,
        let rootLine = String(data: top.output, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
        !rootLine.isEmpty
    else { fail("pathem: not a git repository: \(start)", 1) }
    let root = URL(fileURLWithPath: rootLine).standardizedFileURL.path
    let status = git(["status", "--porcelain", "-z", "--untracked-files=all"], in: root)
    guard status.status == 0 else { fail("pathem: git status failed in \(root)", 1) }

    // Deleted files cannot be revealed, so keep only paths that still exist; newest first.
    let existing: [(relative: String, modified: Date)] = PathemCLI.parsePorcelainZ(status.output)
        .compactMap { relative in
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: root + "/" + relative)
            guard let modified = attributes?[.modificationDate] as? Date else { return nil }
            return (relative, modified)
        }
        .sorted { $0.modified > $1.modified }
    guard let newest = existing.first else {
        print("no uncommitted changes")
        exit(0)
    }
    for other in existing.dropFirst() { print(other.relative) }
    fflush(stdout)
    deliver(verb: .reveal, path: root + "/" + newest.relative, printOnly: printOnly)
}
