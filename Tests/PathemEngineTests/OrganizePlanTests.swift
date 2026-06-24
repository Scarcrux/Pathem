import Foundation
import Testing

@testable import PathemEngine

@Suite struct OrganizePlanTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-org-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func executesMoveTrashAndLabel() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("a".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try Data("b".utf8).write(to: dir.appendingPathComponent("b.txt"))
        try Data("c".utf8).write(to: dir.appendingPathComponent("c.txt"))

        let plan = OrganizePlan(steps: [
            .init(action: .move, file: "a.txt", destination: "Text"),
            .init(action: .trash, file: "b.txt"),
            .init(action: .label, file: "c.txt", label: "Important"),
        ])
        let result = plan.execute(in: dir)
        #expect(result.moved == 1)
        #expect(result.trashed == 1)
        #expect(result.labeled == 1)
        #expect(result.failures.isEmpty)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Text/a.txt").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("b.txt").path))
        #expect(FileTags.tags(of: dir.appendingPathComponent("c.txt")).contains { $0.name == "Important" })
    }

    @Test func rejectsPathTraversalAndMissingFiles() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let plan = OrganizePlan(steps: [
            .init(action: .trash, file: "../escape.txt"),  // traversal
            .init(action: .move, file: "ghost.txt", destination: "X"),  // missing
        ])
        let result = plan.execute(in: dir)
        #expect(result.moved == 0)
        #expect(result.trashed == 0)
        #expect(result.failures.count == 2)
    }

    @Test func rejectsParentDestinationEscape() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("f.txt"))
        // destination ".." has no slash but resolves to the parent: must be refused.
        let plan = OrganizePlan(steps: [.init(action: .move, file: "f.txt", destination: "..")])
        let result = plan.execute(in: dir)
        #expect(result.moved == 0)
        #expect(result.failures == ["f.txt"])
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("f.txt").path))  // stayed put
        #expect(
            !FileManager.default.fileExists(
                atPath: dir.deletingLastPathComponent().appendingPathComponent("f.txt").path))  // never escaped
    }

    @Test func labelIsIdempotentNotAToggle() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("f.txt"))
        let plan = OrganizePlan(steps: [.init(action: .label, file: "f.txt", label: "Important")])
        _ = plan.execute(in: dir)
        _ = plan.execute(in: dir)  // running twice must NOT remove the label
        #expect(
            FileTags.tags(of: dir.appendingPathComponent("f.txt")).contains { $0.name == "Important" })
    }

    @Test func nameCollisionMoveCountsAsFailureNotSuccess() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("a".utf8).write(to: dir.appendingPathComponent("f.txt"))
        // Pre-create the destination with a colliding name so the move skips.
        let sub = dir.appendingPathComponent("Sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("existing".utf8).write(to: sub.appendingPathComponent("f.txt"))

        let result = OrganizePlan(steps: [.init(action: .move, file: "f.txt", destination: "Sub")])
            .execute(in: dir)
        #expect(result.moved == 0)  // skipped, not "moved"
        #expect(result.failures == ["f.txt"])
        #expect(result.performed.isEmpty)
    }

    @Test func decodesModelStyleJSON() throws {
        let json = #"{"steps":[{"action":"move","file":"x.png","destination":"Images"}]}"#
        let plan = try JSONDecoder().decode(OrganizePlan.self, from: Data(json.utf8))
        #expect(plan.steps.first?.action == .move)
        #expect(plan.steps.first?.destination == "Images")
    }
}
