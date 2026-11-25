import Darwin
import Foundation

/// A validated, on-disk extension: its parsed manifest and the folder it lives in. Loading
/// only reads and checks the manifest; nothing is executed until `ExtensionHost.invoke`.
public struct LoadedExtension: Sendable, Equatable {
    public let manifest: ExtensionManifest
    public let directory: URL
    public let signature: ExtensionSignature?
    public var executableURL: URL { directory.appendingPathComponent(manifest.executable) }
}

/// The out-of-process extension runtime seam. It discovers and validates extension bundles,
/// then runs a helper for a single request/response exchange over stdio. Every helper runs
/// as a separate short-lived process, so a crash or hang is isolated to that call and the
/// host (which holds Full Disk Access) is never asked to load foreign code in-process
/// (DESIGN.md: no disable-library-validation, clean Hardened Runtime).
///
/// This is the seam, gated off by default in the app. It exists so the manifest format and
/// the transport are fixed and tested before any extension runtime ships.
public enum ExtensionHost {
    /// How strict the host is when loading and running a helper.
    public struct Policy: Sendable {
        /// Require the helper to be code-signed with the manifest's declared Team ID.
        public var requireSignature: Bool
        var requireHandshake: Bool { requireSignature || testHandshake }
        var testHandshake = false
        /// Kill a helper (and fail the call) if it doesn't answer within this window.
        public var timeout: Duration

        public init(requireSignature: Bool = true, timeout: Duration = .seconds(10)) {
            self.requireSignature = requireSignature
            self.timeout = timeout
        }

        /// Shipping default: signature required.
        public static let production = Policy(requireSignature: true)
        /// For tests and local development against unsigned helpers.
        public static let development = Policy(requireSignature: false, timeout: .seconds(5))
    }

    public enum ExtensionError: Error, Equatable {
        case notADirectory
        case missingManifest
        case invalidManifest(String)
        case incompatibleHostVersion(needs: String)
        case executableMissing(String)
        case notSigned(expectedTeamID: String)
        case invalidSignature
        case approvalRequired
        case isolationUnavailable
        case outputLimit
        case busy
        case protocolMismatch
        case remoteFailure(ExtensionProtocol.Failure)
        case launchFailed(String)
        case helperCrashed(status: Int32, stderr: String)
        case malformedResponse(String)
        case handlerError(String)
        case timedOut
    }

    public static var isolationAvailable: Bool { ExtensionExecution.isolated }

    private static let executionSlots = DispatchSemaphore(value: 4)

    static let manifestFilename = "manifest.json"

    /// Discover every extension in `directory` (each in its own subfolder holding a
    /// `manifest.json`). Invalid bundles are skipped, not fatal — one broken extension
    /// must not take out the rest. Returns the valid ones, sorted by id.
    public static func discover(
        in directory: URL, hostVersion: String, policy: Policy = .production
    ) -> [LoadedExtension] {
        let fm = FileManager.default
        guard
            let subdirs = try? fm.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        else { return [] }
        var loaded: [LoadedExtension] = []
        for sub in subdirs {
            guard (try? sub.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                continue
            }
            if let ext = try? load(sub, hostVersion: hostVersion, policy: policy) {
                loaded.append(ext)
            }
        }
        let grouped = Dictionary(grouping: loaded, by: { $0.manifest.id })
        return grouped.values.filter { $0.count == 1 }.compactMap(\.first)
            .sorted { $0.manifest.id < $1.manifest.id }
    }

    /// Read, decode, and validate a single extension bundle. Throws (without running
    /// anything) if the manifest is missing/invalid, the host is too old, the executable
    /// is absent, or (under a signing policy) the helper isn't signed with the declared
    /// Team ID.
    public static func load(
        _ bundleDir: URL, hostVersion: String, policy: Policy = .production
    ) throws -> LoadedExtension {
        let fm = FileManager.default
        let info = try bundleDir.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard info.isDirectory == true, info.isSymbolicLink != true else {
            throw ExtensionError.notADirectory
        }
        let manifestURL = bundleDir.appendingPathComponent(manifestFilename)
        guard (try? requireUnlinkedPath(manifestFilename, in: bundleDir)) != nil,
            let file = try? openRegularFile(manifestURL)
        else {
            throw ExtensionError.missingManifest
        }
        defer { try? file.close() }
        let data = try file.read(upToCount: 128 * 1024 + 1) ?? Data()
        let manifest: ExtensionManifest
        do {
            try ExtensionProtocol.checkJSON(data, limit: 128 * 1024)
            manifest = try JSONDecoder().decode(ExtensionManifest.self, from: data)
        } catch {
            throw ExtensionError.invalidManifest(String(describing: error))
        }
        try validate(manifest)

        if let needs = manifest.minHostVersion, !versionAtLeast(hostVersion, needs) {
            throw ExtensionError.incompatibleHostVersion(needs: needs)
        }

        try requireUnlinkedPath(manifest.executable, in: bundleDir)
        let executable = bundleDir.appendingPathComponent(manifest.executable)
        guard fm.isExecutableFile(atPath: executable.path) else {
            throw ExtensionError.executableMissing(manifest.executable)
        }
        let signature = policy.requireSignature ? try ExtensionSignature.verify(executable) : nil
        if let signature, let asserted = manifest.teamID, asserted != signature.teamID {
            throw ExtensionError.notSigned(expectedTeamID: asserted)
        }
        return LoadedExtension(manifest: manifest, directory: bundleDir, signature: signature)
    }

    private static func openRegularFile(_ url: URL) throws -> FileHandle {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw ExtensionError.executableMissing(url.lastPathComponent) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            close(fd)
            throw ExtensionError.executableMissing(url.lastPathComponent)
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private static func stageExecutable(_ source: URL, at destination: URL) throws {
        let input = try openRegularFile(source)
        let fd = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o500)
        guard fd >= 0 else {
            throw ExtensionError.launchFailed("Could not stage the extension executable.")
        }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer {
            try? input.close()
            try? output.close()
        }
        var total = 0
        while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
            total += chunk.count
            guard total <= 128 * 1024 * 1024 else {
                throw ExtensionError.launchFailed("Extension executable exceeds the size limit.")
            }
            try output.write(contentsOf: chunk)
        }
    }

    private static func requireUnlinkedPath(_ path: String, in root: URL) throws {
        var current = root
        let pieces = path.split(separator: "/")
        for (index, piece) in pieces.enumerated() {
            current.appendPathComponent(String(piece))
            let values = try current.resourceValues(
                forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
            let expected = index == pieces.count - 1 ? values.isRegularFile : values.isDirectory
            guard values.isSymbolicLink != true && expected == true else {
                throw ExtensionError.executableMissing(path)
            }
        }
    }

    public static func invoke(
        _ ext: LoadedExtension, handler: String, arguments: [String: JSONValue] = [:],
        context: ExtensionProtocol.Context? = nil, policy: Policy = .production,
        approval: ExtensionApproval? = nil
    ) async throws -> JSONValue {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    with: Result {
                        try invokeSync(
                            ext, handler: handler, arguments: arguments, context: context,
                            policy: policy, approval: approval)
                    })
            }
        }
    }

    private static func invokeSync(
        _ ext: LoadedExtension, handler: String, arguments: [String: JSONValue],
        context: ExtensionProtocol.Context?, policy: Policy, approval: ExtensionApproval?
    ) throws -> JSONValue {
        guard executionSlots.wait(timeout: .now()) == .success else {
            throw ExtensionError.busy
        }
        defer { executionSlots.signal() }
        let fm = FileManager.default
        if policy.requireSignature {
            guard let approval, approval.matches(ext) else {
                throw ExtensionError.approvalRequired
            }
            guard isolationAvailable else { throw ExtensionError.isolationUnavailable }
            guard
                let current = try? load(
                    ext.directory, hostVersion: ext.manifest.minHostVersion ?? "0"),
                approval.matches(current)
            else { throw ExtensionError.approvalRequired }
        }
        try requireUnlinkedPath(ext.manifest.executable, in: ext.directory)
        let work = fm.temporaryDirectory.appendingPathComponent(
            "pathem-extension-" + UUID().uuidString)
        try fm.createDirectory(
            at: work, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }
        let data = work.appendingPathComponent("data")
        try fm.createDirectory(
            at: data, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let executable = work.appendingPathComponent("helper")
        try stageExecutable(ext.executableURL, at: executable)

        func exchange(_ request: ExtensionProtocol.Request) throws -> ExtensionProtocol.Response {
            if policy.requireSignature {
                guard try ExtensionSignature.verify(executable) == approval?.signature else {
                    throw ExtensionError.approvalRequired
                }
            }
            let input = try ExtensionProtocol.encodeLine(request)
            let output = try ExtensionExecution.run(
                executable, directory: data, input: input,
                timeout: policy.timeout, isolated: policy.requireSignature)
            let response: ExtensionProtocol.Response
            do {
                response = try ExtensionProtocol.decodeResponse(
                    output, strict: policy.requireHandshake)
            } catch {
                throw ExtensionError.malformedResponse("Expected one bounded JSON response.")
            }
            if policy.requireHandshake {
                guard response.protocolVersion == ExtensionProtocol.version,
                    response.requestID == request.requestID,
                    response.capabilities == request.capabilities
                else { throw ExtensionError.protocolMismatch }
            }
            return response
        }

        if policy.requireHandshake {
            let hello = try exchange(.init(handler: ExtensionProtocol.hello))
            guard hello.ok else { throw ExtensionError.protocolMismatch }
        }
        let response = try exchange(
            .init(handler: handler, arguments: arguments, context: context))
        if response.ok { return response.result ?? .null }
        if let failure = response.failure { throw ExtensionError.remoteFailure(failure) }
        if policy.requireHandshake { throw ExtensionError.protocolMismatch }
        throw ExtensionError.handlerError(response.error ?? "The extension reported an error.")
    }

    // MARK: - Validation

    static func validate(_ m: ExtensionManifest) throws {
        func nonEmpty(_ s: String, _ field: String) throws {
            if s.trimmingCharacters(in: .whitespaces).isEmpty {
                throw ExtensionError.invalidManifest("\(field) is required")
            }
        }
        try nonEmpty(m.id, "id")
        // Reverse-DNS-ish: at least one dot, no path separators or spaces.
        guard m.id.utf8.count <= 128,
            m.id.split(separator: ".", omittingEmptySubsequences: false).count >= 2,
            m.id.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ part in
                !part.isEmpty
                    && part.utf8.allSatisfy {
                        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                            || $0 == 45
                    }
            })
        else {
            throw ExtensionError.invalidManifest("id must be a reverse-DNS identifier")
        }
        try nonEmpty(m.name, "name")
        try nonEmpty(m.version, "version")
        let commands = m.contributes.commands
        guard Set(commands.map(\.id)).count == commands.count,
            commands.allSatisfy({
                !$0.id.isEmpty && !$0.title.isEmpty && !$0.handler.isEmpty
                    && $0.handler != ExtensionProtocol.hello
            })
        else {
            throw ExtensionError.invalidManifest(
                "Commands need unique IDs and non-reserved handlers.")
        }
        try nonEmpty(m.executable, "executable")
        // The executable path must stay inside the bundle (no traversal, no absolute path).
        guard !m.executable.hasPrefix("/"), !m.executable.contains("..") else {
            throw ExtensionError.invalidManifest(
                "executable must be a relative path within the bundle")
        }
    }

    /// Compare dotted numeric versions: is `have` >= `need`? Missing components read as 0.
    static func versionAtLeast(_ have: String, _ need: String) -> Bool {
        let a = have.split(separator: ".").map { Int($0) ?? 0 }
        let b = need.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return true
    }

}
