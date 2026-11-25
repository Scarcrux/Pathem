import Foundation
import PathemEngine

// A reference Pathem extension helper. It reads ONE JSON request line from stdin, dispatches
// on the handler name, and writes ONE JSON response line to stdout, then exits. This is the
// exact shape a real out-of-process Swift extension takes (DESIGN.md: line-delimited JSON
// over stdio). It shares the wire
// types with the host by importing PathemEngine, so both sides encode/decode identically.
//
// The paired manifest.json declares these handlers as contributed commands/columns:
//   { "id": "com.scarcrux.pathem.example", "name": "Example", "version": "1.0.0",
//     "teamID": "REPLACE", "executable": "pathem-ext-example",
//     "contributes": { "commands": [
//        { "id": "ping", "title": "Ping", "handler": "ping" },
//        { "id": "wordCount", "title": "Word Count", "handler": "wordCount" } ] } }

func respond(_ response: ExtensionProtocol.Response) -> Never {
    if let data = try? JSONEncoder().encode(response) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
    exit(0)  // The reply carries handler errors.
}

func handle(_ request: ExtensionProtocol.Request) -> ExtensionProtocol.Response {
    switch request.handler {
    case "ping":
        return .success(.string("pong"))

    case "wordCount":
        // Count whitespace-separated words in the file named by the "path" argument, or in
        // the current selection if no argument is given.
        let path = request.arguments["path"]?.stringValue ?? request.context?.selection.first
        guard let path else { return .failure("wordCount needs a 'path' argument or a selection") }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return .failure("couldn't read \(path)")
        }
        let words = text.split { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }
        return .success(.number(Double(words.count)))

    default:
        return .failure("unknown handler: \(request.handler)")
    }
}

guard let line = readLine(strippingNewline: true), let data = line.data(using: .utf8) else {
    FileHandle.standardError.write(Data("no request on stdin\n".utf8))
    exit(2)
}
do {
    let request = try JSONDecoder().decode(ExtensionProtocol.Request.self, from: data)
    guard request.protocolVersion == ExtensionProtocol.version else {
        respond(.failure("Unsupported protocol version").replying(to: request))
    }
    let reply: ExtensionProtocol.Response =
        request.handler == ExtensionProtocol.hello ? .success() : handle(request)
    respond(reply.replying(to: request))
} catch {
    FileHandle.standardError.write(Data("bad request: \(error)\n".utf8))
    exit(1)
}
