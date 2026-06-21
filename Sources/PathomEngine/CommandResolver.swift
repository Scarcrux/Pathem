import Foundation

/// Maps a natural-language request to the best command id (DESIGN.md section 10,
/// Phase 5). This is the model-free fallback: word overlap against command
/// titles, augmented with a few synonyms, with a relevance floor so an
/// unrecognized request returns nil rather than firing something random. It runs
/// on every Mac; the Foundation Models path (app layer) overrides it with real
/// language understanding when Apple Intelligence is available.
public enum CommandResolver {
    public static func resolve(_ query: String, commands: [(id: String, title: String)]) -> String? {
        var queryWords = Set(tokenize(query.lowercased()))
        guard !queryWords.isEmpty, !commands.isEmpty else { return nil }
        for word in queryWords { synonyms[word].map { queryWords.formUnion($0) } }

        var best: (id: String, score: Int)?
        for command in commands {
            let titleWords = Set(tokenize(command.title.lowercased()))
            var score = 0
            for word in queryWords where word.count >= 2 {
                if titleWords.contains(word) {
                    score += 10  // exact word match
                } else if word.count >= 4, titleWords.contains(where: { $0.hasPrefix(word) }) {
                    score += 5  // prefix match (e.g. "config" -> "configure")
                }
            }
            if score > (best?.score ?? -1) { best = (command.id, score) }
        }
        guard let best, best.score >= 10 else { return nil }
        return best.id
    }

    /// Map a request word to extra title-vocabulary words it implies, so a
    /// request can match a title that uses different wording ("up" -> "Enclosing
    /// Folder").
    private static let synonyms: [String: [String]] = [
        "up": ["enclosing"], "parent": ["enclosing"], "ascend": ["enclosing"],
        "dotfiles": ["hidden"], "invisible": ["hidden"], "reveal": ["show"],
        "recursive": ["subfolders"], "recursively": ["subfolders"], "descendants": ["subfolders"],
        "commands": ["command", "palette"], "actions": ["command", "palette"],
        "duplicate": ["copy"], "previous": ["back"], "next": ["forward"],
    ]

    private static let stopwords: Set<String> = [
        "the", "a", "an", "to", "in", "of", "this", "that", "these", "those", "my",
        "please", "file", "files", "it", "into", "on", "with", "and", "go", "for", "me",
    ]

    private static func tokenize(_ string: String) -> [String] {
        string
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !stopwords.contains($0) }
    }
}
