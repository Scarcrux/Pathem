import Foundation
import PathemEngine

#if canImport(FoundationModels)
    import FoundationModels

    /// The on-device model's structured output for an organize request. Plain fields
    /// mapped to the engine's `OrganizePlan` (the model proposes; our code validates
    /// and executes).
    @available(macOS 26, *)
    @Generable
    struct GeneratedOrganizePlan {
        @Guide(description: "One step per file to act on; omit files to leave alone.")
        var steps: [GeneratedOrganizeStep]
    }

    @available(macOS 26, *)
    @Generable
    struct CleanupAdvice {
        @Guide(description: "The 0-based indices of items that are SAFE to delete.")
        var safeToDelete: [Int]
        @Guide(description: "One short sentence summarizing the recommendation.")
        var summary: String
    }

    /// Ask the on-device model which scanned cleanup items are safe to delete.
    @available(macOS 26, *)
    func recommendCleanup(items: [(path: String, size: Int64, reason: String)]) async -> (
        safeToDelete: [Int], summary: String
    )? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        let session = LanguageModelSession(
            instructions: """
                You help reclaim disk space. Given a numbered list of files and folders with sizes and
                why each was flagged, return the indices that are SAFE to delete: regenerable caches,
                build artifacts, duplicate copies, and obvious junk. Be conservative: never recommend
                deleting documents, photos, or anything ambiguous.
                """)
        // Lead with the natural-language question (guided generation needs the prompt to
        // classify as English, which a list-first prompt can fail to do).
        var prompt = "Which of these items are safe to delete? Return their indices.\n\n"
        for (index, item) in items.enumerated() {
            let size = ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
            prompt += "\(index): \(item.path) (\(size), \(item.reason))\n"
        }
        guard let response = try? await session.respond(to: prompt, generating: CleanupAdvice.self) else {
            return nil
        }
        return (response.content.safeToDelete, response.content.summary)
    }

    @available(macOS 26, *)
    @Generable
    struct GeneratedOrganizeStep {
        @Guide(description: "One of: move, trash, label")
        var action: String
        @Guide(description: "The exact file name from the provided list")
        var file: String
        @Guide(description: "Destination subfolder name, when action is move")
        var destination: String?
        @Guide(description: "Label name, when action is label")
        var label: String?
    }

    /// Ask the on-device model to propose an OrganizePlan for the given files. A free
    /// function so both the browser and the headless AI smoke can call it.
    @available(macOS 26, *)
    func proposeOrganizePlan(instruction: String, files: [String]) async -> OrganizePlan? {
        guard case .available = SystemLanguageModel.default.availability else {
            print("[organize] unavailable: \(SystemLanguageModel.default.availability)")
            return nil
        }
        let session = LanguageModelSession(
            instructions: """
                You organize files in a single folder. You are given a list of file names and an
                instruction. Return a plan of steps. Each step's `file` must be exactly one of the
                provided names. Use action "move" with a `destination` subfolder, "label" with a
                `label`, or "trash". Only include files the instruction calls for.
                """)
        // Lead with the natural-language instruction so the on-device model's language
        // classifier reliably detects English; a filename-dominated prompt (the list
        // first) can classify as "undetermined" and fail guided generation.
        let prompt =
            "Instruction: \(instruction)\n\nApply it to these files, using their exact names:\n"
            + files.joined(separator: "\n")
        let generated: LanguageModelSession.Response<GeneratedOrganizePlan>
        do {
            generated = try await session.respond(to: prompt, generating: GeneratedOrganizePlan.self)
        } catch {
            print("[organize] respond error: \(error)")
            return nil
        }
        let steps = generated.content.steps.compactMap { step -> OrganizePlan.Step? in
            guard let action = OrganizePlan.Action(rawValue: step.action.lowercased()) else { return nil }
            return OrganizePlan.Step(
                action: action, file: step.file, destination: step.destination, label: step.label)
        }
        return OrganizePlan(steps: steps)
    }
#endif
