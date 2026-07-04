import Foundation
import Testing

@testable import PathemEngine

@Suite struct ExtensionHostTests {
    private let hostVersion = "0.8.0"

    /// Write an executable POSIX-sh helper into a bundle dir alongside a manifest pointing
    /// at it. Returns the bundle directory. Cleanup is the caller's (defer removeItem).
    private func makeBundle(
        id: String = "com.scarcrux.pathem.test", script: String, executableName: String = "helper.sh"
    ) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pathem-ext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let helper = dir.appendingPathComponent(executableName)
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let manifest = ExtensionManifest(
            id: id, name: "Test", version: "1.0.0", executable: executableName,
            contributes: .init(commands: [.init(id: "ping", title: "Ping", handler: "ping")]))
        try JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        return dir
    }

    @Test func loadsAValidBundle() throws {
        let dir = try makeBundle(script: "#!/bin/sh\nread l\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let ext = try ExtensionHost.load(dir, hostVersion: hostVersion, policy: .development)
        #expect(ext.manifest.id == "com.scarcrux.pathem.test")
        #expect(ext.executableURL.lastPathComponent == "helper.sh")
    }

    @Test func loadFailsWithoutManifest() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pathem-ext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: ExtensionHost.ExtensionError.missingManifest) {
            try ExtensionHost.load(dir, hostVersion: hostVersion, policy: .development)
        }
    }

    @Test func loadFailsOnTooOldHost() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pathem-ext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let helper = dir.appendingPathComponent("h.sh")
        try Data("#!/bin/sh\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let manifest = ExtensionManifest(
            id: "com.a.b", name: "X", version: "1.0.0", minHostVersion: "9.9.9", executable: "h.sh")
        try JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        #expect(throws: ExtensionHost.ExtensionError.incompatibleHostVersion(needs: "9.9.9")) {
            try ExtensionHost.load(dir, hostVersion: "0.8.0", policy: .development)
        }
    }

    @Test func productionPolicyRejectsUnsignedHelper() throws {
        // The sh helper isn't signed with any Team ID, so a signature-requiring policy
        // must refuse to load it.
        let dir = try makeBundle(script: "#!/bin/sh\nread l\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: ExtensionHost.ExtensionError.self) {
            try ExtensionHost.load(dir, hostVersion: hostVersion, policy: .production)
        }
    }

    @Test func invokesHelperAndDecodesResult() async throws {
        let dir = try makeBundle(script: "#!/bin/sh\nread l\nprintf '{\"ok\":true,\"result\":\"pong\"}\\n'\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let ext = try ExtensionHost.load(dir, hostVersion: hostVersion, policy: .development)
        let result = try await ExtensionHost.invoke(ext, handler: "ping", policy: .development)
        #expect(result == .string("pong"))
    }

    @Test func helperErrorSurfacesAsHandlerError() async throws {
        let dir = try makeBundle(script: "#!/bin/sh\nread l\nprintf '{\"ok\":false,\"error\":\"nope\"}\\n'\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let ext = try ExtensionHost.load(dir, hostVersion: hostVersion, policy: .development)
        await #expect(throws: ExtensionHost.ExtensionError.handlerError("nope")) {
            try await ExtensionHost.invoke(ext, handler: "ping", policy: .development)
        }
    }

    @Test func crashingHelperIsIsolated() async throws {
        let dir = try makeBundle(script: "#!/bin/sh\nread l\nexit 3\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let ext = try ExtensionHost.load(dir, hostVersion: hostVersion, policy: .development)
        await #expect(throws: ExtensionHost.ExtensionError.self) {
            try await ExtensionHost.invoke(ext, handler: "ping", policy: .development)
        }
    }

    @Test func hangingHelperTimesOut() async throws {
        let dir = try makeBundle(script: "#!/bin/sh\nread l\nsleep 10\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let ext = try ExtensionHost.load(dir, hostVersion: hostVersion, policy: .development)
        let policy = ExtensionHost.Policy(requireSignature: false, timeout: .milliseconds(400))
        await #expect(throws: ExtensionHost.ExtensionError.timedOut) {
            try await ExtensionHost.invoke(ext, handler: "ping", policy: policy)
        }
    }

    @Test func discoverSkipsBrokenBundlesAndSortsById() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pathem-exts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Two valid bundles and one broken (no manifest).
        for id in ["com.z.ext", "com.a.ext"] {
            let dir = try makeBundle(id: id, script: "#!/bin/sh\nread l\n")
            try FileManager.default.moveItem(at: dir, to: root.appendingPathComponent(id))
        }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("broken"), withIntermediateDirectories: true)

        let found = ExtensionHost.discover(in: root, hostVersion: hostVersion, policy: .development)
        #expect(found.map(\.manifest.id) == ["com.a.ext", "com.z.ext"])  // sorted, broken skipped
    }

    /// End-to-end against the real reference Swift helper (pathem-ext-example), proving both
    /// sides speak the same wire protocol. Skips cleanly if the build product isn't present.
    @Test func realSwiftHelperSpeaksProtocol() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let built = ["debug", "release"]
            .map { root.appendingPathComponent(".build/\($0)/pathem-ext-example") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        guard let built else { return }  // helper not built in this configuration; skip

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pathem-ext-real-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.copyItem(at: built, to: dir.appendingPathComponent("helper"))
        let manifest = ExtensionManifest(
            id: "com.scarcrux.pathem.example", name: "Example", version: "1.0.0", executable: "helper",
            contributes: .init(commands: [
                .init(id: "ping", title: "Ping", handler: "ping"),
                .init(id: "wordCount", title: "Word Count", handler: "wordCount"),
            ]))
        try JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))

        let ext = try ExtensionHost.load(dir, hostVersion: hostVersion, policy: .development)
        let pong = try await ExtensionHost.invoke(ext, handler: "ping", policy: .development)
        #expect(pong == .string("pong"))

        let sample = dir.appendingPathComponent("sample.txt")
        try Data("one two three four".utf8).write(to: sample)
        let count = try await ExtensionHost.invoke(
            ext, handler: "wordCount", arguments: ["path": .string(sample.path)], policy: .development)
        #expect(count == .number(4))
    }
}
