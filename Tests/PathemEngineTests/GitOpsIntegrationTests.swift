import Foundation
import Testing

@testable import PathemEngine

@Suite struct GitOpsIntegrationTests {
    private func git(_ args: [String], in dir: URL) async throws {
        _ = try await RemoteRunner.run(
            GitStatus.git, ["-C", dir.path] + args, env: GitStatus.subprocessEnvironment)
    }

    @Test func stagesAndCommits() async throws {
        guard FileManager.default.isExecutableFile(atPath: GitStatus.git) else { return }  // no git: skip
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pathem-gitops-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try await git(["init", "-q"], in: dir)
        try await git(["config", "user.email", "t@example.com"], in: dir)
        try await git(["config", "user.name", "Test"], in: dir)
        try await git(["config", "core.hooksPath", "/dev/null"], in: dir)
        try "hello".data(using: .utf8)!.write(to: dir.appendingPathComponent("a.txt"))

        let staged = await GitOps.stageAll(in: dir)
        #expect(staged.ok)
        #expect(await GitOps.hasStagedChanges(in: dir))

        let committed = await GitOps.commit("test: add a.txt", in: dir)
        #expect(committed.ok)
        #expect(!(await GitOps.hasStagedChanges(in: dir)))

        // Working tree is now clean.
        let info = await GitStatus.status(for: dir)
        #expect(info?.states.isEmpty == true)

        // Committing again with nothing staged fails cleanly (not a crash).
        #expect(await GitOps.commit("nothing", in: dir).ok == false)
    }
}
