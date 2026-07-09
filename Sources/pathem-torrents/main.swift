import Foundation
import PathemEngine
import TorrentKit

// The Torrent Inspector plugin: an out-of-process Pathem extension helper. It reads ONE JSON
// request line from stdin, dispatches on the handler, and writes ONE JSON response line to
// stdout, then exits (the ExtensionHost wire protocol). It only READS a local .torrent
// metadata file (bencode) -- no networking, no downloading -- and reports its contents.

func respond(_ response: ExtensionProtocol.Response) -> Never {
    if let data = try? JSONEncoder().encode(response) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
    exit(0)
}

/// The .torrent files in the request's selection (or the "path" argument).
func selectedTorrents(_ request: ExtensionProtocol.Request) -> [String] {
    if let path = request.arguments["path"]?.stringValue { return [path] }
    return (request.context?.selection ?? []).filter { $0.lowercased().hasSuffix(".torrent") }
}

func humanSize(_ bytes: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    return f.string(fromByteCount: bytes)
}

func summarize(_ t: TorrentFile) -> String {
    var lines = [
        t.name,
        "\(humanSize(t.totalLength)) · \(t.files.count) file\(t.files.count == 1 ? "" : "s") · \(t.pieceCount) pieces",
        "Info hash: \(t.infoHashHex)",
    ]
    if t.isPrivate { lines.append("Private torrent") }
    if let comment = t.comment { lines.append("Comment: \(comment)") }
    if let by = t.createdBy { lines.append("Created by: \(by)") }
    if !t.trackers.isEmpty { lines.append("Trackers:\n  " + t.trackers.prefix(8).joined(separator: "\n  ")) }
    let shown = t.files.prefix(30)
    lines.append("Files:\n" + shown.map { "  \($0.path)  (\(humanSize($0.length)))" }.joined(separator: "\n"))
    if t.files.count > shown.count { lines.append("  … and \(t.files.count - shown.count) more") }
    return lines.joined(separator: "\n")
}

func handle(_ request: ExtensionProtocol.Request) -> ExtensionProtocol.Response {
    let torrents = selectedTorrents(request)
    guard !torrents.isEmpty else { return .failure("Select a .torrent file first.") }
    switch request.handler {
    case "inspect":
        var blocks: [String] = []
        for path in torrents {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
                blocks.append("Couldn't read \((path as NSString).lastPathComponent)")
                continue
            }
            do { blocks.append(summarize(try TorrentFile.parse(data))) } catch {
                blocks.append("\((path as NSString).lastPathComponent): not a valid torrent (\(error))")
            }
        }
        return .success(.string(blocks.joined(separator: "\n\n───\n\n")))

    case "magnet":
        var links: [String] = []
        for path in torrents {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                let t = try? TorrentFile.parse(data)
            else { continue }
            links.append(t.magnetLink)
        }
        guard !links.isEmpty else { return .failure("Couldn't read a magnet link.") }
        return .success(.string(links.joined(separator: "\n")))

    default:
        return .failure("unknown handler: \(request.handler)")
    }
}

guard let line = readLine(strippingNewline: true), let data = line.data(using: .utf8) else {
    FileHandle.standardError.write(Data("no request on stdin\n".utf8))
    exit(2)
}
do {
    respond(handle(try JSONDecoder().decode(ExtensionProtocol.Request.self, from: data)))
} catch {
    FileHandle.standardError.write(Data("bad request: \(error)\n".utf8))
    exit(1)
}
