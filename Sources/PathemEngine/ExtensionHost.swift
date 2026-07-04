import Foundation

/// A validated, on-disk extension: its parsed manifest and the folder it lives in. Loading
/// only reads and checks the manifest; nothing is executed until `ExtensionHost.invoke`.
public struct LoadedExtension: Sendable, Equatable {
    public let manifest: ExtensionManifest
    public let directory: URL
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
        case launchFailed(String)
        case helperCrashed(status: Int32, stderr: String)
        case malformedResponse(String)
        case handlerError(String)
        case timedOut
    }

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
                at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }
        var loaded: [LoadedExtension] = []
        for sub in subdirs {
            guard (try? sub.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            if let ext = try? load(sub, hostVersion: hostVersion, policy: policy) {
                loaded.append(ext)
            }
        }
        return loaded.sorted { $0.manifest.id < $1.manifest.id }
    }

    /// Read, decode, and validate a single extension bundle. Throws (without running
    /// anything) if the manifest is missing/invalid, the host is too old, the executable
    /// is absent, or (under a signing policy) the helper isn't signed with the declared
    /// Team ID.
    public static func load(
        _ bundleDir: URL, hostVersion: String, policy: Policy = .production
    ) throws -> LoadedExtension {
        let fm = FileManager.default
        guard (try? bundleDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
            throw ExtensionError.notADirectory
        }
        let manifestURL = bundleDir.appendingPathComponent(manifestFilename)
        guard let data = try? Data(contentsOf: manifestURL) else {
            throw ExtensionError.missingManifest
        }
        let manifest: ExtensionManifest
        do {
            manifest = try JSONDecoder().decode(ExtensionManifest.self, from: data)
        } catch {
            throw ExtensionError.invalidManifest(String(describing: error))
        }
        try validate(manifest)

        if let needs = manifest.minHostVersion, !versionAtLeast(hostVersion, needs) {
            throw ExtensionError.incompatibleHostVersion(needs: needs)
        }

        let ext = LoadedExtension(manifest: manifest, directory: bundleDir)
        guard fm.isExecutableFile(atPath: ext.executableURL.path) else {
            throw ExtensionError.executableMissing(manifest.executable)
        }
        if policy.requireSignature {
            let expected = manifest.teamID ?? ""
            let actual = CodeSignature.teamID(of: ext.executableURL)
            guard !expected.isEmpty, actual == expected else {
                throw ExtensionError.notSigned(expectedTeamID: expected)
            }
        }
        return ext
    }

    /// Run one handler in the helper out-of-process and return its result. Builds a single
    /// JSON request line, feeds it to the helper's stdin, and reads one JSON response line
    /// from stdout. The helper is launched with a minimal environment (it inherits none of
    /// the host's), and is killed if it exceeds the policy timeout.
    public static func invoke(
        _ ext: LoadedExtension, handler: String, arguments: [String: JSONValue] = [:],
        context: ExtensionProtocol.Context? = nil, policy: Policy = .production
    ) async throws -> JSONValue {
        let request = ExtensionProtocol.Request(handler: handler, arguments: arguments, context: context)
        let line = try ExtensionProtocol.encodeLine(request)
        // A deliberately spare environment: the helper gets a PATH and nothing else from us.
        let env = ["PATH": "/usr/bin:/bin"]

        let data: Data
        let status: Int32
        let stderr: String
        do {
            (data, status, stderr) = try await withTimeout(policy.timeout) {
                try await RemoteRunner.run(
                    ext.executableURL.path, [], input: String(decoding: line, as: UTF8.self), env: env)
            }
        } catch is TimedOut {
            throw ExtensionError.timedOut
        } catch {
            throw ExtensionError.launchFailed(String(describing: error))
        }

        guard status == 0 else {
            throw ExtensionError.helperCrashed(
                status: status, stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let response: ExtensionProtocol.Response
        do {
            response = try ExtensionProtocol.decodeResponse(data)
        } catch let e as ExtensionProtocol.MalformedResponse {
            throw ExtensionError.malformedResponse(e.detail)
        } catch {
            throw ExtensionError.malformedResponse(String(describing: error))
        }
        guard response.ok else {
            throw ExtensionError.handlerError(response.error ?? "The extension reported an error.")
        }
        return response.result ?? .null
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
        guard m.id.contains("."), !m.id.contains("/"), !m.id.contains(" ") else {
            throw ExtensionError.invalidManifest("id must be a reverse-DNS identifier")
        }
        try nonEmpty(m.name, "name")
        try nonEmpty(m.version, "version")
        try nonEmpty(m.executable, "executable")
        // The executable path must stay inside the bundle (no traversal, no absolute path).
        guard !m.executable.hasPrefix("/"), !m.executable.contains("..") else {
            throw ExtensionError.invalidManifest("executable must be a relative path within the bundle")
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

    // MARK: - Timeout

    private struct TimedOut: Error {}

    /// Race a body against a deadline. The body's own cancellation (RemoteRunner honors it)
    /// tears down the helper process when the deadline wins.
    private static func withTimeout<T: Sendable>(
        _ timeout: Duration, _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TimedOut()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw TimedOut() }
            return first
        }
    }
}

/// Reads the Team ID from a file's code signature via `codesign`, out-of-process. Returns
/// nil for an unsigned or ad-hoc-signed file. Used to gate which helpers the host will run.
enum CodeSignature {
    static func teamID(of url: URL) -> String? {
        guard
            let (_, status, err) = try? runSyncCodesign(url), status == 0
        else { return nil }
        // codesign prints "TeamIdentifier=XXXXXXXXXX" (or "not set") to stderr with -dv.
        for line in err.split(separator: "\n") where line.hasPrefix("TeamIdentifier=") {
            let value = line.dropFirst("TeamIdentifier=".count).trimmingCharacters(in: .whitespaces)
            return (value.isEmpty || value == "not set") ? nil : value
        }
        return nil
    }

    private static func runSyncCodesign(_ url: URL) throws -> (Data, Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dv", "--verbose=2", url.path]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (outData, process.terminationStatus, String(decoding: errData, as: UTF8.self))
    }
}
