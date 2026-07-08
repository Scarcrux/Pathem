import Foundation
import Testing

@testable import PathemEngine

@Suite struct ACLEditorTests {
    private func tempFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-acl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("file.txt")
        try Data("x".utf8).write(to: url)
        return url
    }

    @Test func addsAndRemovesAnEntry() throws {
        let url = try tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(FileMetadata.aclEntries(of: url) == nil)  // none to start

        let user = NSUserName()
        #expect(ACLEditor.add(principal: user, allow: true, permissions: ["read", "write"], to: url) == nil)
        let entries = FileMetadata.aclEntries(of: url)
        #expect(entries != nil)
        #expect(entries?.contains { $0.contains(user) } == true)

        #expect(ACLEditor.removeEntry(at: 0, from: url) == nil)
        #expect(FileMetadata.aclEntries(of: url) == nil)  // back to no extended ACL
    }

    @Test func rejectsEmptyInput() throws {
        let url = try tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(ACLEditor.add(principal: "", allow: true, permissions: ["read"], to: url) != nil)
        #expect(ACLEditor.add(principal: NSUserName(), allow: true, permissions: [], to: url) != nil)
    }
}
