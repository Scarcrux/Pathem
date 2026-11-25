import Darwin
import Foundation
import Testing

@testable import PathemEngine

@Suite(.serialized) struct ExtensionHostTests {
    private let hostVersion = "0.8.0"

    /// Write an executable POSIX-sh helper into a bundle dir alongside a manifest pointing
    /// at it. Returns the bundle directory. Cleanup is the caller's (defer removeItem).
    private func makeBundle(
        id: String = "com.scarcrux.pathem.test", script: String,
        executableName: String = "helper.sh"
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
        let dir = try makeBundle(
            script: "#!/bin/sh\nread l\nprintf '{\"ok\":true,\"result\":\"pong\"}\\n'\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let ext = try ExtensionHost.load(dir, hostVersion: hostVersion, policy: .development)
        let result = try await ExtensionHost.invoke(ext, handler: "ping", policy: .development)
        #expect(result == .string("pong"))
    }

    @Test func helperErrorSurfacesAsHandlerError() async throws {
        let dir = try makeBundle(
            script: "#!/bin/sh\nread l\nprintf '{\"ok\":false,\"error\":\"nope\"}\\n'\n")
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

    @Test func productionInvocationRequiresApprovalBeforeLaunch() async throws {
        let directory = try makeBundle(script: "#!/bin/sh\nexit 99\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        let ext = try ExtensionHost.load(directory, hostVersion: hostVersion, policy: .development)
        await #expect(throws: ExtensionHost.ExtensionError.approvalRequired) {
            try await ExtensionHost.invoke(ext, handler: "ping")
        }
    }

    @Test func symlinkedExecutableIsRejected() throws {
        let directory = try makeBundle(script: "#!/bin/sh\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("helper.sh")
        try FileManager.default.removeItem(at: helper)
        try FileManager.default.createSymbolicLink(
            at: helper, withDestinationURL: URL(fileURLWithPath: "/bin/true"))
        #expect(throws: ExtensionHost.ExtensionError.executableMissing("helper.sh")) {
            try ExtensionHost.load(directory, hostVersion: hostVersion, policy: .development)
        }
    }

    @Test func signatureValidationRejectsTamperedCopy() throws {
        let directory = try makeBundle(script: "#!/bin/sh\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("signed")
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: helper.path)
        _ = try ExtensionSignature.verify(helper, requireDeveloperID: false)
        var data = try Data(contentsOf: helper)
        try #require(data.count > 4096)
        data[4096] ^= 1
        try data.write(to: helper)
        #expect(throws: ExtensionHost.ExtensionError.invalidSignature) {
            try ExtensionSignature.verify(helper, requireDeveloperID: false)
        }
    }

    @Test func responsibilityProbeFailsClosedWithMissingSymbols() throws {
        let launcher = try #require(ExtensionExecution.launcher)
        #expect(!ExtensionExecution.probe(launcher, omitSymbols: true))
        if ExtensionExecution.probe(launcher) {
            let reply = try ExtensionExecution.run(
                URL(fileURLWithPath: "/bin/cat"), directory: FileManager.default.temporaryDirectory,
                input: Data("probe".utf8), timeout: .seconds(2), isolated: true)
            #expect(reply == Data("probe".utf8))
        }
    }

    @Test func mismatchedHelloRefusesToSendHandler() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("pathem-extension-handler-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let directory = try makeBundle(
            script: #"""
                #!/bin/sh
                read line
                case "$line" in
                  *"__hello"*) ;;
                  *) /usr/bin/touch '\#(marker.path)' ;;
                esac
                request_id=$(printf '%s' "$line" | /usr/bin/sed -E 's/.*"requestID":"([^"]+)".*/\1/')
                printf '{"ok":true,"protocolVersion":99,"capabilities":["commands"],"requestID":"%s"}\n' "$request_id"
                """#)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ext = try ExtensionHost.load(directory, hostVersion: hostVersion, policy: .development)
        var policy = ExtensionHost.Policy.development
        policy.testHandshake = true
        await #expect(throws: ExtensionHost.ExtensionError.protocolMismatch) {
            try await ExtensionHost.invoke(ext, handler: "ping", policy: policy)
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func helperOutputCapsApplyToBothStreams() async throws {
        for redirect in ["", " >&2"] {
            let directory = try makeBundle(
                script: "#!/bin/sh\n/usr/bin/yes overflow" + redirect + "\n")
            defer { try? FileManager.default.removeItem(at: directory) }
            let ext = try ExtensionHost.load(
                directory, hostVersion: hostVersion, policy: .development)
            await #expect(throws: ExtensionHost.ExtensionError.outputLimit) {
                try await ExtensionHost.invoke(ext, handler: "ping", policy: .development)
            }
        }
    }

    @Test func timeoutKillsGrandchildBeforeItCanWrite() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("pathem-extension-grandchild-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let directory = try makeBundle(
            script: """
                #!/bin/sh
                ( /bin/sleep 1; /usr/bin/touch '\(marker.path)' ) &
                wait
                """)
        defer { try? FileManager.default.removeItem(at: directory) }
        let policy = ExtensionHost.Policy(requireSignature: false, timeout: .milliseconds(300))
        let ext = try ExtensionHost.load(directory, hostVersion: hostVersion, policy: policy)
        await #expect(throws: ExtensionHost.ExtensionError.timedOut) {
            try await ExtensionHost.invoke(ext, handler: "ping", policy: policy)
        }
        try await Task.sleep(for: .seconds(1))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func helperGetsPrivateCWDAndNoInheritedDescriptor() async throws {
        let fd = open("/dev/null", O_RDONLY | O_CLOEXEC)
        try #require(fd >= 0)
        defer { close(fd) }
        let inherited = fcntl(fd, F_DUPFD, 100)
        try #require(inherited >= 100)
        defer { close(inherited) }
        let directory = try makeBundle(
            script: """
                #!/bin/sh
                [ "$(/bin/pwd -P)" = "$(cd "$HOME" && /bin/pwd -P)" ] || exit 2
                [ -z "$TMPDIR" ] || exit 3
                [ ! -e "/dev/fd/\(inherited)" ] || exit 4
                [ "$(ulimit -t)" = 10 ] || exit 5
                printf '{"ok":true,"result":"isolated"}\n'
                """)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ext = try ExtensionHost.load(directory, hostVersion: hostVersion, policy: .development)
        let result = try await ExtensionHost.invoke(ext, handler: "ping", policy: .development)
        #expect(result == .string("isolated"))
    }

    /// End-to-end against the real reference Swift helper (pathem-ext-example), proving both
    /// sides speak the same wire protocol.
    @Test func realSwiftHelperSpeaksProtocol() async throws {
        let built = try #require(ExtensionExecution.findExecutable("pathem-ext-example"))

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pathem-ext-real-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.copyItem(at: built, to: dir.appendingPathComponent("helper"))
        let manifest = ExtensionManifest(
            id: "com.scarcrux.pathem.example", name: "Example", version: "1.0.0",
            executable: "helper",
            contributes: .init(commands: [
                .init(id: "ping", title: "Ping", handler: "ping"),
                .init(id: "wordCount", title: "Word Count", handler: "wordCount"),
            ]))
        try JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))

        let ext = try ExtensionHost.load(dir, hostVersion: hostVersion, policy: .development)
        var policy = ExtensionHost.Policy.development
        policy.testHandshake = true
        let pong = try await ExtensionHost.invoke(ext, handler: "ping", policy: policy)
        #expect(pong == .string("pong"))

        let sample = dir.appendingPathComponent("sample.txt")
        try Data("one two three four".utf8).write(to: sample)
        let count = try await ExtensionHost.invoke(
            ext, handler: "wordCount", arguments: ["path": .string(sample.path)], policy: policy)
        #expect(count == .number(4))
    }
}
