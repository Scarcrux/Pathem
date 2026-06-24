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

    extension BrowserViewController {
        /// Ask the on-device model to propose an OrganizePlan for the given files.
        @available(macOS 26, *)
        func proposeOrganizePlan(instruction: String, files: [String]) async -> OrganizePlan? {
            guard case .available = SystemLanguageModel.default.availability else { return nil }
            let session = LanguageModelSession(
                instructions: """
                    You organize files in a single folder. You are given a list of file names and an
                    instruction. Return a plan of steps. Each step's `file` must be exactly one of the
                    provided names. Use action "move" with a `destination` subfolder, "label" with a
                    `label`, or "trash". Only include files the instruction calls for.
                    """)
            let prompt = "Files:\n\(files.joined(separator: "\n"))\n\nInstruction: \(instruction)"
            guard
                let generated = try? await session.respond(to: prompt, generating: GeneratedOrganizePlan.self)
            else { return nil }
            let steps = generated.content.steps.compactMap { step -> OrganizePlan.Step? in
                guard let action = OrganizePlan.Action(rawValue: step.action.lowercased()) else { return nil }
                return OrganizePlan.Step(
                    action: action, file: step.file, destination: step.destination, label: step.label)
            }
            return OrganizePlan(steps: steps)
        }
    }
#endif
