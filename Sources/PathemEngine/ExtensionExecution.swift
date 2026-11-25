import Foundation
import OSLog
import PathemExtensionRuntime

private final class ExtensionRuntimeAnchor: NSObject {}

enum ExtensionExecution {
    private static let logger = Logger(subsystem: "com.scarcrux.pathem", category: "Extensions")
    static let launcher = findExecutable("pathem-ext-launch")

    static func findExecutable(_ name: String) -> URL? {
        let packaged = Bundle.main.bundleURL.pathExtension == "app"
        let binaries = [
            Bundle.main.executableURL, Bundle(for: ExtensionRuntimeAnchor.self).executableURL,
        ]
        for binary in (packaged ? Array(binaries.prefix(1)) : binaries).compactMap({ $0 }) {
            var directory = binary.deletingLastPathComponent()
            for _ in 0..<(packaged ? 1 : 5) {
                let candidate = directory.appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
                directory.deleteLastPathComponent()
            }
        }
        return nil
    }

    // Static initialization caches only in this process. A new process always tests its
    // running OS build and bundled launcher, even if previous launches succeeded.
    static let isolated: Bool = {
        let result = launcher.map { probe($0) } ?? false
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        logger.notice("Extension responsibility self-test on \(os, privacy: .public): \(result)")
        return result
    }()

    static func probe(_ launcher: URL, omitSymbols: Bool = false) -> Bool {
        pe_isolation_probe(launcher.path, NSTemporaryDirectory(), omitSymbols ? 1 : 0) == 1
    }

    static func run(
        _ executable: URL, directory: URL, input: Data, timeout: Duration, isolated: Bool
    ) throws -> Data {
        guard let launcher else { throw ExtensionHost.ExtensionError.isolationUnavailable }
        let time = timeout.components
        let milliseconds = Double(time.seconds) * 1_000 + Double(time.attoseconds) / 1e15
        var output = [UInt8](repeating: 0, count: ExtensionProtocol.maximumBytes)
        var errors = [UInt8](repeating: 0, count: 64 * 1024)
        let result = input.withUnsafeBytes { bytes in
            pe_run(
                launcher.path, executable.path, directory.path,
                bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count,
                &output, output.count, &errors, errors.count,
                Int32(min(60_000, max(1, milliseconds))), isolated ? 1 : 0)
        }
        switch Int(result.result) {
        case pe_ok:
            guard result.status == 0 else {
                throw ExtensionHost.ExtensionError.helperCrashed(
                    status: result.status,
                    stderr: String(decoding: errors.prefix(result.error_length), as: UTF8.self))
            }
            return Data(output.prefix(result.output_length))
        case pe_timeout: throw ExtensionHost.ExtensionError.timedOut
        case pe_output_limit: throw ExtensionHost.ExtensionError.outputLimit
        case pe_isolation_failed: throw ExtensionHost.ExtensionError.isolationUnavailable
        default:
            throw ExtensionHost.ExtensionError.launchFailed(
                "Could not start or read the extension helper.")
        }
    }
}
