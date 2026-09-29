import Foundation
import PathemEngine

// The `pathem` command-line tool: `pathem reveal <path>` selects an item in Pathem (in its parent
// folder), `pathem open <dir>` navigates into a folder, and `pathem preview <file>` opens the
// read-only viewer. It resolves the path to absolute and hands
// it to the running (or launched) app over the pathem:// URL scheme -- the one stable seam every
// editor/Finder-handoff integration targets, so their config never has to know the launch details.

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let arguments = CommandLine.arguments
guard arguments.count == 3, let verb = PathemURLContract.Verb(rawValue: arguments[1]) else {
    fail("usage: pathem <open|reveal|preview> <path>", 2)
}

let raw = arguments[2]
let absolute =
    (raw as NSString).isAbsolutePath
    ? raw
    : FileManager.default.currentDirectoryPath + "/" + raw
let path = URL(fileURLWithPath: absolute).standardizedFileURL.path
guard FileManager.default.fileExists(atPath: path) else {
    fail("pathem: no such file or directory: \(raw)", 1)
}
guard let url = PathemURLContract.url(verb: verb, path: path) else {
    fail("pathem: could not form a URL for \(raw)", 1)
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
