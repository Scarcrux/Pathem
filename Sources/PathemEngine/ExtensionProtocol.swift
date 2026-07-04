import Foundation

/// The wire protocol between the host and an out-of-process Swift extension helper. One
/// request is written to the helper's stdin as a single JSON line; the helper writes one
/// JSON response line to stdout and exits. Line-delimited JSON over stdio (DESIGN.md), so
/// the helper is trivially crash-isolated and inherits none of the host's ambient state.
public enum ExtensionProtocol {
    /// Bumped on any breaking change to `Request`/`Response`. The host sends its version;
    /// a helper that can't speak it should fail cleanly.
    public static let version = 1

    /// Read-only context the host chooses to share for a call. The host passes only what a
    /// command needs (the current folder, the selected paths); the helper gets no other
    /// handle to the host or its file-system grants.
    public struct Context: Codable, Sendable, Equatable {
        public var folder: String?
        public var selection: [String]
        public init(folder: String? = nil, selection: [String] = []) {
            self.folder = folder
            self.selection = selection
        }
    }

    /// A single host -> helper call.
    public struct Request: Codable, Sendable, Equatable {
        public var protocolVersion: Int
        /// The contributed handler name to run (from the manifest).
        public var handler: String
        public var arguments: [String: JSONValue]
        public var context: Context?

        public init(
            handler: String, arguments: [String: JSONValue] = [:], context: Context? = nil,
            protocolVersion: Int = ExtensionProtocol.version
        ) {
            self.protocolVersion = protocolVersion
            self.handler = handler
            self.arguments = arguments
            self.context = context
        }
    }

    /// The helper's single reply. `ok == false` carries a human-readable `error`.
    public struct Response: Codable, Sendable, Equatable {
        public var ok: Bool
        public var result: JSONValue?
        public var error: String?

        public init(ok: Bool, result: JSONValue? = nil, error: String? = nil) {
            self.ok = ok
            self.result = result
            self.error = error
        }

        public static func success(_ result: JSONValue? = nil) -> Response {
            Response(ok: true, result: result)
        }
        public static func failure(_ message: String) -> Response {
            Response(ok: false, error: message)
        }
    }

    /// Signals a response that couldn't be framed or parsed.
    public struct MalformedResponse: Error, Equatable {
        public let detail: String
        public init(_ detail: String) { self.detail = detail }
    }

    /// Encode a request as one newline-terminated JSON line (the helper reads one line).
    public static func encodeLine(_ request: Request) throws -> Data {
        var data = try JSONEncoder().encode(request)
        data.append(0x0A)  // "\n"
        return data
    }

    /// Decode a helper's response from its stdout, taking the first non-empty line.
    public static func decodeResponse(_ stdout: Data) throws -> Response {
        let text = String(decoding: stdout, as: UTF8.self)
        guard let line = text.split(separator: "\n").first(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) else {
            throw MalformedResponse("The helper produced no response line.")
        }
        do {
            return try JSONDecoder().decode(Response.self, from: Data(line.utf8))
        } catch {
            throw MalformedResponse("The helper's response wasn't valid JSON: \(line)")
        }
    }
}
