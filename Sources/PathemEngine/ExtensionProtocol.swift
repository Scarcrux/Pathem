import Foundation

/// The wire protocol between the host and an out-of-process Swift extension helper. One
/// request is written to the helper's stdin as a single JSON line; the helper writes one
/// JSON response line to stdout and exits. Line-delimited JSON over stdio (DESIGN.md), so
/// the helper is trivially crash-isolated and inherits none of the host's ambient state.
public enum ExtensionProtocol {
    /// Bumped on any breaking change to `Request`/`Response`. The host sends its version;
    /// a helper that can't speak it should fail cleanly.
    public static let version = 1
    public static let maximumBytes = 1024 * 1024
    public static let capabilities = ["commands"]
    public static let hello = "__hello"

    static func checkJSON(_ data: Data, limit: Int = maximumBytes) throws {
        guard data.count <= limit, String(data: data, encoding: .utf8) != nil else {
            throw MalformedResponse("Invalid UTF-8 or JSON byte limit exceeded.")
        }
        var depth = 0
        var quoted = false
        var escaped = false
        for byte in data {
            if quoted {
                if escaped {
                    escaped = false
                } else if byte == 92 {
                    escaped = true
                } else if byte == 34 {
                    quoted = false
                }
            } else if byte == 34 {
                quoted = true
            } else if byte == 123 || byte == 91 {
                depth += 1
                guard depth <= 32 else { throw MalformedResponse("JSON nesting limit exceeded.") }
            } else if byte == 125 || byte == 93 {
                depth -= 1
                guard depth >= 0 else { throw MalformedResponse("Invalid JSON structure.") }
            }
        }
    }

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
        public var requestID: UUID
        public var capabilities: [String]
        /// The contributed handler name to run (from the manifest).
        public var handler: String
        public var arguments: [String: JSONValue]
        public var context: Context?

        public init(
            handler: String, arguments: [String: JSONValue] = [:], context: Context? = nil,
            protocolVersion: Int = ExtensionProtocol.version, requestID: UUID = UUID(),
            capabilities: [String] = ExtensionProtocol.capabilities
        ) {
            self.protocolVersion = protocolVersion
            self.requestID = requestID
            self.capabilities = capabilities
            self.handler = handler
            self.arguments = arguments
            self.context = context
        }
    }

    public struct Failure: Codable, Sendable, Equatable {
        public let code: String
        public let message: String
        public let recoverable: Bool

        public init(code: String, message: String, recoverable: Bool) {
            self.code = code
            self.message = message
            self.recoverable = recoverable
        }
    }

    /// The helper's single reply. `ok == false` carries a human-readable `error`.
    public struct Response: Codable, Sendable, Equatable {
        public var ok: Bool
        public var result: JSONValue?
        public var error: String?
        public var failure: Failure?
        public var protocolVersion: Int?
        public var requestID: UUID?
        public var capabilities: [String]?

        public init(ok: Bool, result: JSONValue? = nil, error: String? = nil) {
            self.ok = ok
            self.result = result
            self.error = error
        }

        public func replying(to request: Request) -> Self {
            var reply = self
            reply.protocolVersion = ExtensionProtocol.version
            reply.requestID = request.requestID
            reply.capabilities = ExtensionProtocol.capabilities
            if !ok && failure == nil {
                reply.failure = Failure(
                    code: "handler_failed", message: error ?? "Handler failed.", recoverable: false)
            }
            return reply
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
        try checkJSON(data, limit: maximumBytes - 1)
        data.append(0x0A)  // "\n"
        return data
    }

    /// Decode a helper's response from its stdout, taking the first non-empty line.
    public static func decodeResponse(_ stdout: Data, strict: Bool = false) throws -> Response {
        guard stdout.count <= maximumBytes, let text = String(data: stdout, encoding: .utf8) else {
            throw MalformedResponse("Invalid response encoding or size.")
        }
        if strict
            && text.split(separator: "\n").filter({
                !$0.trimmingCharacters(in: .whitespaces).isEmpty
            }).count != 1
        {
            throw MalformedResponse("Expected one response line.")
        }
        guard
            let line = text.split(separator: "\n").first(where: {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty
            })
        else {
            throw MalformedResponse("The helper produced no response line.")
        }
        do {
            let bytes = Data(line.utf8)
            try checkJSON(bytes)
            return try JSONDecoder().decode(Response.self, from: bytes)
        } catch {
            throw MalformedResponse("The helper response was invalid or exceeded the JSON bounds.")
        }
    }
}
