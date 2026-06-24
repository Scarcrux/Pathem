import Foundation

/// User-defined macros: a named, ordered list of existing command IDs run as one
/// action. Config-as-data (macros.json), so no scripting runtime is needed — a
/// macro registers as a normal command, shows up in the palette, and is bindable to
/// a key like any other (keeps the Swift-only-extensions rule intact).
public struct Macro: Codable, Sendable, Equatable {
    public var name: String
    public var commands: [String]

    public init(name: String, commands: [String]) {
        self.name = name
        self.commands = commands
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        commands = try c.decodeIfPresent([String].self, forKey: .commands) ?? []
    }

    private enum CodingKeys: String, CodingKey { case name, commands }
}

public struct Macros: Codable, Sendable, Equatable {
    public var macros: [Macro]

    public init(macros: [Macro]) { self.macros = macros }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        macros = try c.decodeIfPresent([Macro].self, forKey: .macros) ?? []
    }

    private enum CodingKeys: String, CodingKey { case macros }

    /// A starter macro showing the idea (chain Flat View then the filter); users add
    /// their own in macros.json.
    public static let `default` = Macros(macros: [
        Macro(name: "Flatten & Filter", commands: ["view.flatView", "view.filter"])
    ])
}
