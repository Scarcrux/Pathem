import Foundation

/// A typed, previewable plan of file operations — the safe core of natural-language
/// organizing: a model (or any source) PROPOSES a plan, and THIS code validates and
/// executes it through the existing file operations. The model never touches the
/// filesystem. Pure logic, unit-tested; the LLM frontend is layered on top and
/// gated to where the on-device model exists.
public struct OrganizePlan: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable, Equatable { case move, trash, label }

    public struct Step: Codable, Sendable, Equatable {
        public var action: Action
        /// File name within the base folder.
        public var file: String
        /// Destination subfolder name (for `move`).
        public var destination: String?
        /// Label name (for `label`).
        public var label: String?

        public init(action: Action, file: String, destination: String? = nil, label: String? = nil) {
            self.action = action
            self.file = file
            self.destination = destination
            self.label = label
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            action = (try? c.decode(Action.self, forKey: .action)) ?? .label
            file = try c.decodeIfPresent(String.self, forKey: .file) ?? ""
            destination = try c.decodeIfPresent(String.self, forKey: .destination)
            label = try c.decodeIfPresent(String.self, forKey: .label)
        }

        private enum CodingKeys: String, CodingKey { case action, file, destination, label }
    }

    public var steps: [Step]
    public init(steps: [Step]) { self.steps = steps }

    public struct Result: Sendable, Equatable {
        public var moved = 0
        public var trashed = 0
        public var labeled = 0
        public var failures: [String] = []
    }

    /// A human-readable preview (one line per step) for a confirmation dialog.
    public func summary(in folder: URL) -> [String] {
        steps.compactMap { step in
            switch step.action {
            case .move: return step.destination.map { "Move \(step.file) → \($0)/" }
            case .trash: return "Trash \(step.file)"
            case .label: return step.label.map { "Label \(step.file): \($0)" }
            }
        }
    }

    /// Execute the plan in `folder` via the existing file operations. Skips steps
    /// whose file is missing or whose required field is absent (never acts outside
    /// the folder or on a path it wasn't given).
    public func execute(in folder: URL) -> Result {
        let fm = FileManager.default
        var result = Result()
        for step in steps {
            // Reject anything that isn't a bare name in this folder (no traversal).
            guard !step.file.isEmpty, !step.file.contains("/"), step.file != "..", step.file != "." else {
                result.failures.append(step.file)
                continue
            }
            let src = folder.appendingPathComponent(step.file)
            guard fm.fileExists(atPath: src.path) else {
                result.failures.append(step.file)
                continue
            }
            switch step.action {
            case .move:
                guard let dest = step.destination, !dest.isEmpty, !dest.contains("/") else {
                    result.failures.append(step.file)
                    continue
                }
                let destDir = folder.appendingPathComponent(dest)
                try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)
                let outcome = FileOperations.move(urls: [src], into: destDir)
                if outcome.failures.isEmpty { result.moved += 1 } else { result.failures.append(step.file) }
            case .trash:
                let trash = FileOperations.trash(urls: [src])
                if trash.failures.isEmpty { result.trashed += 1 } else { result.failures.append(step.file) }
            case .label:
                guard let label = step.label, !label.isEmpty else {
                    result.failures.append(step.file)
                    continue
                }
                let color = LabelSet.default.labels.first { $0.name == label }?.color ?? .none
                do {
                    _ = try FileTags.toggle(FileTag(name: label, color: color), on: src)
                    result.labeled += 1
                } catch {
                    result.failures.append(step.file)
                }
            }
        }
        return result
    }
}
