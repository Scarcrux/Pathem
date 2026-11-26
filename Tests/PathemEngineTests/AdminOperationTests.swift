import Darwin
import Foundation
import Security
import Testing

@testable import PathemEngine

@Suite struct AdminOperationTests {
    @Test func requestBoundaryDistinguishesPermissionFromOtherFailures() {
        let permission = POSIXError(.EACCES)
        let notFound = POSIXError(.ENOENT)
        let wrapped = NSError(
            domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
            userInfo: [NSUnderlyingErrorKey: POSIXError(.EPERM)])
        #expect(AdminFileRequest.isPermissionFailure(permission))
        #expect(AdminFileRequest.isPermissionFailure(wrapped))
        #expect(!AdminFileRequest.isPermissionFailure(notFound))
        #expect(
            !AdminFileRequest.isPermissionFailure(
                NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)))
        #expect(
            !AdminFileRequest.isPermissionFailure(
                BulkEnumerator.EnumerationError.openFailed(path: "/fixture", errno: ENOENT)))
        #expect(
            AdminFileRequest.isPermissionFailure(
                BulkEnumerator.EnumerationError.openFailed(path: "/fixture", errno: EACCES)))
    }

    @Test(.enabled(if: geteuid() != 0))
    func realRenameInReadOnlyDirectoryReportsPermissionFailure() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        defer {
            _ = chmod(directory.path, 0o700)
            try? fm.removeItem(at: directory)
        }
        let source = directory.appendingPathComponent("original")
        let dest = directory.appendingPathComponent("renamed")
        try Data("fixture".utf8).write(to: source)
        try #require(chmod(directory.path, 0o555) == 0)
        let renameResult = Result {
            try FileOperations.rename("original", to: "renamed", in: directory)
        }
        switch renameResult {
        case .success:
            Issue.record("The read-only directory unexpectedly allowed a rename")
        case .failure(let error):
            var chain: [String] = []
            var current: NSError? = error as NSError
            while let entry = current {
                chain.append("\(entry.domain):\(entry.code)")
                current = entry.userInfo[NSUnderlyingErrorKey] as? NSError
            }
            print("ADMIN RENAME FIXTURE: \(chain.joined(separator: " -> "))")
            #expect(AdminFileRequest.isPermissionFailure(error))
        }
        #expect(try Data(contentsOf: source) == Data("fixture".utf8))
        #expect(!fm.fileExists(atPath: dest.path))
    }

    @Test func signedPeerRequirementsParseAndAuthorizationRuleFailsClosed() throws {
        for identifier in [AdminHelperIdentity.appIdentifier, AdminHelperIdentity.serviceName] {
            var requirement: SecRequirement?
            let expression = AdminHelperIdentity.signingRequirement(for: identifier)
            #expect(expression.contains("identifier \"\(identifier)\""))
            #expect(expression.contains("K466Z7J2AS"))
            #expect(
                SecRequirementCreateWithString(expression as CFString, [], &requirement)
                    == errSecSuccess)
            _ = try #require(requirement)
        }
        let legacy: [String: Any] = ["class": "rule", "rule": ["authenticate-admin"]]
        #expect(AdminAuthorization.isLegacyRule(legacy))
        #expect(AdminAuthorization.isLegacyRule(["class": "rule", "rule": "authenticate-admin"]))
        #expect(!AdminAuthorization.isExpectedRule(legacy))
        #expect(
            !AdminAuthorization.isLegacyRule([
                "class": "rule", "rule": ["authenticate-admin", "allow"],
            ]))
        #expect(
            !AdminAuthorization.isLegacyRule(["class": "allow", "rule": ["authenticate-admin"]]))

        let expected = AdminAuthorization.expectedRule
        #expect(AdminAuthorization.isExpectedRule(expected))
        #expect(!AdminAuthorization.isLegacyRule(expected))
        let invalidValues: [(String, Any)] = [
            ("class", "allow"), ("group", "staff"), ("timeout", 0), ("timeout", 900),
            ("shared", false), ("authenticate-user", false), ("allow-root", true),
            ("session-owner", true), ("rule", "allow"), ("mechanisms", ["builtin:entitled"]),
        ]
        for (key, value) in invalidValues {
            var invalid = expected
            invalid[key] = value
            #expect(!AdminAuthorization.isExpectedRule(invalid), "Unexpected match for \(key)")
        }
        #expect(!AdminAuthorization.verify(Data()))
    }

    @Test func approvedActionsOperateWithinAnIsolatedFixture() throws {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent(
            "pathem-admin-ops-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: scratch) }
        let base = try canonicalAdminFixture(scratch)
        let trash = base.appendingPathComponent("trash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: false)
        let service = AdminFileService(trashRoot: .init(path: trash.path, owner: getuid())) {
            bytes in
            bytes == Data(repeating: 0x6A, count: 32)
        }
        let credentials = Data(repeating: 0x6A, count: 32)
        var granted = false
        service.authorize(credentials, duration: 901) { granted = $0 }
        #expect(!granted)
        service.authorize(credentials, duration: 300) { granted = $0 }
        try #require(granted)

        @discardableResult
        func call(_ request: AdminFileRequest) throws -> Data {
            var data: Data?
            var operationError: NSError?
            service.perform(try JSONEncoder().encode(request)) {
                data = $0
                operationError = $1
            }
            if let operationError { throw operationError }
            return try #require(data)
        }
        let origin = base.appendingPathComponent("origin")
        try call(.init(operation: .createDirectory, source: origin.path))
        let child = origin.appendingPathComponent("file.txt")
        try Data("fixture".utf8).write(to: child)
        let copy = base.appendingPathComponent("copy")
        try call(.init(operation: .copy, source: origin.path, destination: copy.path))
        #expect(
            try Data(contentsOf: copy.appendingPathComponent("file.txt")) == Data("fixture".utf8))
        #expect(throws: (any Error).self) {
            try call(.init(operation: .copy, source: origin.path, destination: copy.path))
        }
        let moved = base.appendingPathComponent("moved")
        try call(.init(operation: .move, source: copy.path, destination: moved.path))
        let renamed = base.appendingPathComponent("renamed")
        try call(.init(operation: .rename, source: moved.path, destination: renamed.path))
        let file = renamed.appendingPathComponent("file.txt")
        try call(.init(operation: .setPermissions, source: file.path, mode: 0o640))
        try call(.init(operation: .setOwner, source: file.path, owner: getuid(), group: getgid()))
        try call(
            .init(
                operation: .setFlags, source: file.path, flags: UInt32(UF_HIDDEN),
                flagMask: UInt32(UF_HIDDEN)))
        let metadata = try JSONDecoder().decode(
            AdminFileAttributes.self, from: call(.init(operation: .attributes, source: file.path)))
        #expect(metadata.mode & 0o777 == 0o640)
        #expect(metadata.owner == getuid())
        #expect(metadata.flags & UInt32(UF_HIDDEN) != 0)
        let listing = try JSONDecoder().decode(
            [AdminDirectoryEntry].self, from: call(.init(operation: .list, source: renamed.path)))
        #expect(listing.map(\.name) == ["file.txt"])
        let movedToTrash = try JSONDecoder().decode(
            String.self, from: call(.init(operation: .trash, source: renamed.path)))
        #expect(movedToTrash == trash.appendingPathComponent("renamed").path)
        #expect(!fm.fileExists(atPath: renamed.path))
        try call(.init(operation: .delete, source: movedToTrash))
        #expect(!fm.fileExists(atPath: movedToTrash))
        #expect(try Data(contentsOf: child) == Data("fixture".utf8))
    }
}
