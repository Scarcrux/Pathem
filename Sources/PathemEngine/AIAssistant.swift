import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device generative AI (Apple Intelligence) for naming and summarizing, via Apple's
/// FoundationModels. Everything is gated on macOS 26 + the model being ready, so each entry
/// point degrades gracefully — `availability` reports why, and the generators return `nil` —
/// on older Macs or machines without Apple Intelligence enabled. Zero network, zero cost,
/// runs entirely on device. Foundation-only (no AppKit); callers await it off the main thread.
public enum AIAssistant {
    public enum Availability: Sendable, Equatable {
        case available
        case unsupportedOS  // < macOS 26 — FoundationModels doesn't exist
        case modelNotReady  // OS is fine, but the model isn't enabled/eligible/downloaded

        /// A short, human-facing reason for the AI being off (empty when available).
        public var reason: String {
            switch self {
            case .available: return ""
            case .unsupportedOS: return "On-device AI needs macOS 26 or later."
            case .modelNotReady:
                return "Apple Intelligence isn’t ready. Turn it on in System Settings and make sure the model has finished downloading."
            }
        }
    }

    /// Whether the on-device model can be used right now.
    public static var availability: Availability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .available
            default: return .modelNotReady
            }
        }
        #endif
        return .unsupportedOS
    }

    public static var isAvailable: Bool { availability == .available }

    /// Suggest a clean, descriptive base filename (no extension) for a file, from its current
    /// name and, when available, a text preview of its content. Returns `nil` if AI is
    /// unavailable, the model errors, or the reply can't be reduced to a usable name. The
    /// caller re-applies the original extension.
    public static func suggestName(currentName: String, content: String?) async -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), isAvailable {
            let base = (currentName as NSString).deletingPathExtension
            var prompt = """
                Suggest a single concise, descriptive filename for this file, without the extension. \
                Use lowercase words separated by hyphens, no more than about six words. Reply with the \
                filename only — no quotes, no explanation, no path.

                Current name: \(base)
                """
            if let content = content?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty {
                prompt += "\n\nA preview of the file’s content:\n\(String(content.prefix(2000)))"
            }
            do {
                let session = LanguageModelSession()
                let response = try await session.respond(to: prompt)
                return sanitizeSuggestedName(response.content)
            } catch {
                return nil
            }
        }
        #endif
        return nil
    }

    /// Summarize what a folder contains, given its name and the names of its items. Returns a
    /// short plain-text paragraph, or `nil` if AI is unavailable or the model errors.
    public static func summarizeFolder(folderName: String, itemNames: [String]) async -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), isAvailable {
            let listed = itemNames.prefix(200).joined(separator: "\n")
            let more = itemNames.count > 200 ? "\n…and \(itemNames.count - 200) more" : ""
            let prompt = """
                Summarize what this folder contains in two or three sentences of plain text. Describe \
                the kinds of files and what they seem to be for. Don’t list every file. Reply with the \
                summary only.

                Folder: \(folderName)
                Items (\(itemNames.count) total):
                \(listed)\(more)
                """
            do {
                let session = LanguageModelSession()
                let response = try await session.respond(to: prompt)
                let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            } catch {
                return nil
            }
        }
        #endif
        return nil
    }

    /// Reduce a model reply to a filesystem-safe base name, or `nil` if nothing usable remains.
    /// Handles the model wrapping its answer in quotes/backticks/markdown, adding a trailing
    /// period, emitting path separators, or replying with a whole sentence (we keep the first
    /// line). Exposed for unit testing — it's pure and doesn't touch the model.
    public static func sanitizeSuggestedName(_ raw: String) -> String? {
        // First non-empty line only — the model sometimes adds a trailing explanation.
        guard var name = raw.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty })
        else { return nil }

        // Strip a leading "Filename:"-style label if present.
        if let colon = name.firstIndex(of: ":"), name[..<colon].count <= 12,
            name[..<colon].lowercased().contains("name") {
            name = String(name[name.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }

        // Peel surrounding quotes/backticks the model likes to add.
        let wrappers: Set<Character> = ["\"", "'", "`", "“", "”", "‘", "’", "*"]
        while let f = name.first, wrappers.contains(f) { name.removeFirst() }
        while let l = name.last, wrappers.contains(l) { name.removeLast() }
        name = name.trimmingCharacters(in: .whitespaces)

        // Drop characters illegal in a macOS filename, plus control chars.
        name = String(name.unicodeScalars.filter { $0 != "/" && $0 != ":" && !CharacterSet.controlCharacters.contains($0) })

        // Collapse internal whitespace runs to single spaces and trim stray leading dots
        // (a hidden file) and trailing dots/spaces.
        name = name.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: " ."))

        // Guard against pathological length; keep it a reasonable filename.
        if name.count > 120 { name = String(name.prefix(120)).trimmingCharacters(in: CharacterSet(charactersIn: " .")) }

        return name.isEmpty ? nil : name
    }
}
