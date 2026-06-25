import Foundation

/// Git write operations (stage, commit, push, pull) for the repo containing a folder.
/// Like GitStatus, these shell out to the system `git` off-process. Each returns
/// whether it succeeded plus git's combined output (for an error dialog).
public enum GitOps {
    public struct Outcome: Sendable, Equatable {
        public let ok: Bool
        public let output: String
    }

    /// Stage every change (tracked modifications, new files, deletions): `git add -A`.
    public static func stageAll(in folder: URL) async -> Outcome {
        await run(["add", "-A"], in: folder)
    }

    /// Commit the staged changes with `message`. Fails (cleanly) if nothing is staged.
    public static func commit(_ message: String, in folder: URL) async -> Outcome {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Outcome(ok: false, output: "Empty commit message") }
        return await run(["commit", "-m", trimmed], in: folder)
    }

    public static func push(in folder: URL) async -> Outcome { await run(["push"], in: folder) }
    public static func pull(in folder: URL) async -> Outcome {
        await run(["pull", "--ff-only"], in: folder)  // never auto-merge: fast-forward or stop
    }

    /// The staged diff, truncated, to give an AI commit-message generator context.
    public static func stagedDiff(in folder: URL, limit: Int = 6000) async -> String {
        let outcome = await run(["diff", "--cached", "--stat", "-p", "--no-color"], in: folder)
        return String(outcome.output.prefix(limit))
    }

    /// Whether there is anything staged to commit.
    public static func hasStagedChanges(in folder: URL) async -> Bool {
        // `git diff --cached --quiet` exits 1 when there ARE staged changes.
        let outcome = await run(["diff", "--cached", "--quiet"], in: folder)
        return !outcome.ok
    }

    private static func run(_ args: [String], in folder: URL) async -> Outcome {
        guard FileManager.default.isExecutableFile(atPath: GitStatus.git) else {
            return Outcome(ok: false, output: "git not found")
        }
        guard let result = try? await RemoteRunner.run(GitStatus.git, ["-C", folder.path] + args) else {
            return Outcome(ok: false, output: "git could not run")
        }
        let combined = String(decoding: result.0, as: UTF8.self) + result.2
        return Outcome(ok: result.1 == 0, output: combined.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
