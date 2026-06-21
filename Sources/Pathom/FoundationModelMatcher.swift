import Foundation

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// Uses Apple's on-device Foundation Model to map a natural-language request to a
/// registry command id (DESIGN.md section 10, Phase 5). This is the upgrade over
/// the engine's CommandResolver heuristic: real language understanding, still
/// fully on-device and free. It only runs on macOS 26+ with Apple Intelligence
/// available; everywhere else it returns nil and the caller falls back to the
/// heuristic.
enum FoundationModelMatcher {
    @available(macOS 26.0, *)
    static func match(_ query: String, to commands: [(id: String, title: String)]) async -> String? {
        #if canImport(FoundationModels)
            guard case .available = SystemLanguageModel.default.availability else { return nil }
            let list = commands.map { "\($0.id): \($0.title)" }.joined(separator: "\n")
            let prompt = """
                Map the user's request to exactly one command id from this list, or reply NONE.
                Reply with only the id (or NONE), nothing else.

                Commands:
                \(list)

                Request: \(query)
                """
            do {
                let session = LanguageModelSession()
                let response = try await session.respond(to: prompt)
                let answer = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                return commands.first { $0.id == answer }?.id
            } catch {
                return nil
            }
        #else
            return nil
        #endif
    }
}
