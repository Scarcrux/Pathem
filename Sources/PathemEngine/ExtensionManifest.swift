import Foundation

/// A minimal, order-preserving JSON value used for extension command arguments and
/// results. Extensions exchange structured data with the host, but the host never
/// evaluates it as code; it is plain data across the process boundary.
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    public var doubleValue: Double? { if case .number(let n) = self { return n } else { return nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { return b } else { return nil } }
}

/// The "contributes" manifest an extension ships as `manifest.json`. This is the stable
/// schema an out-of-process Swift helper declares itself with: identity (reverse-DNS id,
/// version, signing Team ID), the helper executable, and what it adds to the host
/// (commands, columns, viewers, menu items, keybindings, themes). The host reads and
/// validates this WITHOUT running anything; execution only happens later, out-of-process,
/// through `ExtensionHost.invoke`. Designed now so the config format is fixed before any
/// runtime ships (DESIGN.md "Extensions: Swift only, and out-of-process").
public struct ExtensionManifest: Codable, Sendable, Equatable {
    /// Reverse-DNS unique id, e.g. "com.acme.pathem.superzip".
    public let id: String
    public let name: String
    public let version: String
    /// Lowest host version this extension supports (semantic, "x.y.z"); nil = any.
    public let minHostVersion: String?
    /// The Apple Developer Team ID the helper must be signed with. The host refuses to
    /// launch a helper whose code signature doesn't match this (production policy).
    public let teamID: String?
    /// Path to the helper executable, relative to the extension's own folder.
    public let executable: String
    public var contributes: Contributes

    public init(
        id: String, name: String, version: String, minHostVersion: String? = nil,
        teamID: String? = nil, executable: String, contributes: Contributes = Contributes()
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.minHostVersion = minHostVersion
        self.teamID = teamID
        self.executable = executable
        self.contributes = contributes
    }

    public struct Contributes: Codable, Sendable, Equatable {
        public var commands: [Command]
        public var columns: [Column]
        public var viewers: [Viewer]
        public var menuItems: [MenuItem]
        public var keybindings: [Keybinding]
        public var themes: [Theme]

        public init(
            commands: [Command] = [], columns: [Column] = [], viewers: [Viewer] = [],
            menuItems: [MenuItem] = [], keybindings: [Keybinding] = [], themes: [Theme] = []
        ) {
            self.commands = commands
            self.columns = columns
            self.viewers = viewers
            self.menuItems = menuItems
            self.keybindings = keybindings
            self.themes = themes
        }

        // Tolerate a partial manifest: any missing section defaults to empty rather than
        // failing the whole decode (mirrors Preferences' forward-compatible decoding).
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            commands = try c.decodeIfPresent([Command].self, forKey: .commands) ?? []
            columns = try c.decodeIfPresent([Column].self, forKey: .columns) ?? []
            viewers = try c.decodeIfPresent([Viewer].self, forKey: .viewers) ?? []
            menuItems = try c.decodeIfPresent([MenuItem].self, forKey: .menuItems) ?? []
            keybindings = try c.decodeIfPresent([Keybinding].self, forKey: .keybindings) ?? []
            themes = try c.decodeIfPresent([Theme].self, forKey: .themes) ?? []
        }
    }

    /// A command the extension adds. The host exposes it as `ext.<extID>.<id>` on the same
    /// command bus as everything else (palette, menus, keymap), and routes its invocation
    /// to the helper's `handler`.
    public struct Command: Codable, Sendable, Equatable {
        public let id: String
        public let title: String
        public let handler: String
        public init(id: String, title: String, handler: String) {
            self.id = id
            self.title = title
            self.handler = handler
        }
    }

    /// A computed column the helper can fill for a file (e.g. a domain-specific metadata
    /// value). `handler` is invoked with the file path; the result is shown in the column.
    public struct Column: Codable, Sendable, Equatable {
        public let id: String
        public let title: String
        public let handler: String
        public init(id: String, title: String, handler: String) {
            self.id = id
            self.title = title
            self.handler = handler
        }
    }

    /// A preview the helper can render for files of the given UTIs (returns e.g. text or a
    /// path to a rendered image). Keeps third-party viewers out-of-process.
    public struct Viewer: Codable, Sendable, Equatable {
        public let id: String
        public let title: String
        public let utis: [String]
        public let handler: String
        public init(id: String, title: String, utis: [String], handler: String) {
            self.id = id
            self.title = title
            self.utis = utis
            self.handler = handler
        }
    }

    /// Places a contributed command in a menu. `command` references a contributed command id.
    public struct MenuItem: Codable, Sendable, Equatable {
        public let command: String
        public let menu: String
        public init(command: String, menu: String) {
            self.command = command
            self.menu = menu
        }
    }

    /// Binds a chord to a contributed command. `command` references a contributed command id.
    public struct Keybinding: Codable, Sendable, Equatable {
        public let command: String
        public let chord: String
        public init(command: String, chord: String) {
            self.command = command
            self.chord = chord
        }
    }

    /// A theme file the extension ships (e.g. a terminal or UI theme), relative to the
    /// extension folder. Pure data, loaded by the host; no code involved.
    public struct Theme: Codable, Sendable, Equatable {
        public let id: String
        public let name: String
        public let file: String
        public init(id: String, name: String, file: String) {
            self.id = id
            self.name = name
            self.file = file
        }
    }
}
