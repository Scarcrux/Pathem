import Foundation
import Testing

@testable import PathemEngine

@Suite struct OwnershipEditorTests {
    @Test func readsOwnerAndGroupOfATempFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-own-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("f.txt")
        try Data("x".utf8).write(to: url)

        let ownership = OwnershipEditor.read(url)
        #expect(ownership != nil)
        #expect(ownership?.owner == NSUserName())  // we just created it
        #expect(!(ownership?.group.isEmpty ?? true))
    }

    @Test func buildsQuotedChownCommand() {
        let cmd = OwnershipEditor.sudoChownCommand(
            owner: "bob", group: "staff", recursive: false, paths: ["/tmp/a b.txt", "/tmp/c.txt"])
        #expect(cmd == "sudo chown 'bob:staff' '/tmp/a b.txt' '/tmp/c.txt'")
    }

    @Test func ownerOnlyAndRecursive() {
        #expect(
            OwnershipEditor.sudoChownCommand(owner: "bob", group: nil, recursive: true, paths: ["/x"])
                == "sudo chown -R 'bob' '/x'")
        // Group empty is treated as owner-only.
        #expect(
            OwnershipEditor.sudoChownCommand(owner: "bob", group: "", recursive: false, paths: ["/x"])
                == "sudo chown 'bob' '/x'")
    }

    @Test func emptyOwnerOrNoPathsYieldsEmpty() {
        #expect(OwnershipEditor.sudoChownCommand(owner: "", group: "staff", recursive: false, paths: ["/x"]).isEmpty)
        #expect(OwnershipEditor.sudoChownCommand(owner: "bob", group: nil, recursive: false, paths: []).isEmpty)
    }

    @Test func changeGroupAppliesWithoutRoot() throws {
        // Setting the group to the file's current group is a no-op that still exercises the path
        // without needing elevated privileges or a second group the tester belongs to.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-grp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("f.txt")
        try Data("x".utf8).write(to: url)
        let group = OwnershipEditor.read(url)!.group

        let result = BulkAttributes.apply(.init(groupOwnerName: group), to: [url])
        #expect(result.failures.isEmpty)
        #expect(result.changed == 1)
    }
}
