import Darwin
import Foundation
import Testing

@testable import PathemEngine

@Suite struct AdminFileRequestTests {
    @Test func operationAllowlistAndPayloadRejectUnexpectedRequests() throws {
        let valid = AdminFileRequest(
            operation: .copy, source: "/Library/Source", destination: "/Library/Copy")
        let decoded = try AdminFileRequest.decode(JSONEncoder().encode(valid))
        #expect(decoded.operation == .copy)
        #expect(decoded.destination == "/Library/Copy")
        #expect(throws: DecodingError.self) {
            try AdminFileRequest.decode(
                Data(#"{"operation":"exec","source":"/Library/Source"}"#.utf8))
        }
        #expect(throws: AdminFileError.invalidRequest) {
            try AdminFileRequest(operation: .delete, source: "/").validate()
        }
        #expect(throws: AdminFileError.invalidRequest) {
            try AdminFileRequest(operation: .setPermissions, source: "/tmp/file", mode: 0o4777)
                .validate()
        }
        #expect(throws: AdminFileError.invalidRequest) {
            try AdminFileRequest(operation: .list, source: "/", owner: 0).validate()
        }
    }

    @Test(arguments: [
        "/Library/../private", "/Library/./file", "/Library//file", "/Library/",
        "Library/file", "/Library/nul\0file", "/",
    ])
    func mutationRejectsAmbiguousPathComponents(_ path: String) {
        #expect(throws: AdminFileError.invalidRequest) {
            try AdminFileRequest(operation: .delete, source: path).validate()
        }
    }

    @Test func descriptorWalkRefusesIntermediateAndLeafLinks() throws {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory
            .appendingPathComponent("pathem-admin-fixture-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: scratch) }
        // The OS may return /var, which is a symbolic link to /private/var.
        let root = try canonicalAdminFixture(scratch)
        let actual = root.appendingPathComponent("actual")
        try fm.createDirectory(at: actual, withIntermediateDirectories: false)
        let file = actual.appendingPathComponent("file")
        try Data("FIXTURE".utf8).write(to: file)
        let aliasedParent = root.appendingPathComponent("alternate")
        let aliasedLeaf = root.appendingPathComponent("linkedFile")
        try fm.createSymbolicLink(at: aliasedParent, withDestinationURL: actual)
        try fm.createSymbolicLink(at: aliasedLeaf, withDestinationURL: file)

        let attributes = try AdminPath.withParent(of: file.path) { fd, name in
            try AdminPath.attributes(parent: fd, name: name)
        }
        #expect(attributes.st_size == 7)
        #expect(throws: POSIXError.self) {
            try AdminPath.withParent(of: aliasedParent.appendingPathComponent("file").path) {
                _, _ in
                Issue.record("opened an intermediate symbolic link")
            }
        }
        #expect(throws: AdminFileError.symlink) {
            try AdminPath.withParent(of: aliasedLeaf.path) { fd, name in
                try AdminPath.attributes(parent: fd, name: name)
            }
        }
    }
}

/// Foundation can shorten /private/var to /var after resolving a URL. The fixture
/// needs the actual path so the service can refuse every symbolic link uniformly.
func canonicalAdminFixture(_ url: URL) throws -> URL {
    guard let resolved = realpath(url.path, nil) else { throw AdminPath.posixError() }
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
}
