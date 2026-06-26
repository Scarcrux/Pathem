import Foundation
import PathemEngine

// Out-of-process helper for browsing a paired iOS device over AFC. The app invokes this
// (never the AFC stack in the Full-Disk-Access process), like it shells out to curl/sftp.
// Usage:
//   pathem-afc ls    <udid> <path>            -> JSON [{name,dir,size}] on stdout
//   pathem-afc pull  <udid> <remote> <local>
//   pathem-afc push  <udid> <local>  <remote>
//   pathem-afc mkdir <udid> <path>
//   pathem-afc rm    <udid> <path>
//   pathem-afc mv    <udid> <from>   <to>

struct JSONEntry: Encodable {
    let name: String
    let dir: Bool
    let size: Int64
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail("usage: pathem-afc <command> [udid] [args]") }

// `list` enumerates attached iOS devices (udid + connection type); no udid needed.
if command == "list" {
    let devices = (try? USBMux.listDevices()) ?? []
    for device in devices { print("\(device.udid)\t\(device.connectionType)") }
    exit(0)
}

guard args.count >= 2 else { fail("usage: pathem-afc <command> <udid> [args]") }
let udid = args[1]

// `name` is a lightweight lockdown query (no AFC session); handle it before opening AFC.
if command == "name" {
    FileHandle.standardOutput.write(Data((IOSDevice.name(udid: udid) ?? "").utf8))
    exit(0)
}

do {
    let session = try AFCSession.open(udid: udid)
    defer { session.close() }
    switch command {
    case "ls":
        guard args.count >= 3 else { fail("ls needs a path") }
        let entries = try session.list(args[2]).map { JSONEntry(name: $0.name, dir: $0.isDirectory, size: $0.size) }
        let json = try JSONEncoder().encode(entries)
        FileHandle.standardOutput.write(json)
    case "pull":
        guard args.count >= 4 else { fail("pull needs <remote> <local>") }
        try session.readFile(args[2]).write(to: URL(fileURLWithPath: args[3]))
    case "push":
        guard args.count >= 4 else { fail("push needs <local> <remote>") }
        try session.writeFile(args[3], data: Data(contentsOf: URL(fileURLWithPath: args[2])))
    case "mkdir":
        guard args.count >= 3 else { fail("mkdir needs a path") }
        try session.makeDirectory(args[2])
    case "rm":
        guard args.count >= 3 else { fail("rm needs a path") }
        try session.remove(args[2])
    case "mv":
        guard args.count >= 4 else { fail("mv needs <from> <to>") }
        try session.rename(from: args[2], to: args[3])
    default:
        fail("unknown command: \(command)")
    }
} catch {
    fail("\(error)")
}
