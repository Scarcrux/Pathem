import Foundation
import PathemEngine

// Out-of-process helper that browses an Android device over the adb server protocol (the
// adb server on 127.0.0.1:5037, then the sync service). The app invokes this binary, like
// pathem-afc, so the protocol parsing stays out of the app (crash isolation, not a TCC
// boundary). Pure Swift: no adb CLI is needed once a server is running; the CLI is only used
// to start the server when none is listening.
// Usage:
//   pathem-adb devices                         -> JSON [{serial,state,model}] on stdout
//   pathem-adb ls   <serial> <path>            -> JSON [{name,dir,size,mtime}] on stdout
//   pathem-adb pull <serial> <remote> <local>  -> "PROGRESS <done> <total>" lines on stderr
//   pathem-adb push <serial> <local> <remote>  -> "PROGRESS <done> <total>" lines on stderr
// Exit codes follow ADBError.exitCode (2 = protocol failure, so the app may use the CLI).
// SIGTERM cancels a transfer between chunks and removes the partial file.

struct JSONDevice: Encodable {
    let serial: String
    let state: String
    let model: String?
}

struct JSONEntry: Encodable {
    let name: String
    let dir: Bool
    let size: Int64
    let mtime: Double?
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail("usage: pathem-adb <command> [serial] [args]") }

let cancel = CancelFlag()
signal(SIGTERM, SIG_IGN)
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
termSource.setEventHandler { cancel.set() }
termSource.resume()

let port = ADBClient.serverPort()

/// Throttled progress lines on stderr.
let progressClock = ProgressThrottle()
final class ProgressThrottle: @unchecked Sendable {
    private var last = Date.distantPast
    func report(_ done: Int64, _ total: Int64) {
        let now = Date()
        guard now.timeIntervalSince(last) >= 0.1 || done == total else { return }
        last = now
        FileHandle.standardError.write(Data("PROGRESS \(done) \(total)\n".utf8))
    }
}

do {
    let adb = DeviceTools.adb
    try ADBServer.ensureRunning(
        port: port, start: adb.map { ADBServer.starter(adbPath: $0, port: port) })
    let encoder = JSONEncoder()
    switch command {
    case "devices":
        let devices = try ADBClient.devices(port: port).map {
            JSONDevice(serial: $0.serial, state: $0.state, model: $0.model)
        }
        FileHandle.standardOutput.write(try encoder.encode(devices))
    case "ls":
        guard args.count >= 3 else { fail("ls needs <serial> <path>") }
        let sync = try ADBClient.openSync(port: port, serial: args[1])
        defer { sync.close() }
        let directory = args[2].hasSuffix("/") ? String(args[2].dropLast()) : args[2]
        var entries: [JSONEntry] = []
        var links = 0
        for info in try sync.list(directory.isEmpty ? "/" : directory) {
            var isDirectory = info.isDirectory
            // A symlink (like /sdcard/Android/obb on some builds) is a folder when STAT with a
            // trailing slash resolves it to one. Bounded so a link-heavy folder stays quick.
            if info.isSymlink, links < 200 {
                links += 1
                let target = directory.hasSuffix("/") ? directory : directory + "/"
                isDirectory = (try? sync.stat(target + info.name + "/"))?.isDirectory ?? false
            }
            entries.append(
                JSONEntry(
                    name: info.name, dir: isDirectory,
                    size: isDirectory ? 0 : Int64(clamping: info.size),
                    mtime: info.modified?.timeIntervalSince1970))
        }
        FileHandle.standardOutput.write(try encoder.encode(entries))
    case "pull":
        guard args.count >= 4 else { fail("pull needs <serial> <remote> <local>") }
        let sync = try ADBClient.openSync(port: port, serial: args[1])
        defer { sync.close() }
        try sync.pull(
            args[2], to: URL(fileURLWithPath: args[3]),
            progress: { progressClock.report($0, $1) }, isCancelled: { cancel.isSet })
    case "push":
        guard args.count >= 4 else { fail("push needs <serial> <local> <remote>") }
        let sync = try ADBClient.openSync(port: port, serial: args[1])
        defer { sync.close() }
        try sync.push(
            URL(fileURLWithPath: args[2]), to: args[3],
            progress: { progressClock.report($0, $1) }, isCancelled: { cancel.isSet })
    default:
        fail("unknown command: \(command)")
    }
} catch let error as ADBError {
    fail(error.message, code: error.exitCode)
} catch {
    fail("\(error)")
}
