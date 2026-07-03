import Foundation

/// Batch image conversion and resizing via `sips`, the built-in macOS image tool, run
/// out-of-process (per the architecture rule that heavy/third-party work never runs inline
/// in the FDA process). Writes new files next to the originals, never overwriting them.
public enum ImageConverter {
    public enum Format: String, Sendable, CaseIterable {
        case png, jpeg, heic, tiff, gif
        /// The value `sips -s format` expects.
        var sipsName: String { rawValue }
        /// The file extension for the output.
        var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
    }

    public struct Options: Sendable, Equatable {
        /// Target format, or nil to keep the original format.
        public var format: Format?
        /// Resample so the longer side fits within this many pixels, or nil to keep the size.
        public var maxDimension: Int?
        public init(format: Format? = nil, maxDimension: Int? = nil) {
            self.format = format
            self.maxDimension = maxDimension
        }
        public var isNoOp: Bool { format == nil && maxDimension == nil }
    }

    public struct Result: Sendable, Equatable {
        public var outputs: [URL] = []
        public var failures: [FileOperations.Failure] = []
        public init() {}
    }

    /// Convert/resize each image. Sequential (each `sips` call is quick), off-main via the
    /// subprocess runner. A per-item failure is recorded and the batch continues.
    public static func process(_ urls: [URL], options: Options) async -> Result {
        var result = Result()
        guard !options.isNoOp else { return result }
        for url in urls {
            let output = outputURL(for: url, options: options)
            var args: [String] = []
            if let format = options.format { args += ["-s", "format", format.sipsName] }
            if let max = options.maxDimension { args += ["-Z", "\(max)"] }
            args += [url.path, "--out", output.path]
            do {
                let (_, code, stderr) = try await RemoteRunner.run("/usr/bin/sips", args)
                if code == 0 {
                    result.outputs.append(output)
                } else {
                    result.failures.append(
                        .init(
                            name: url.lastPathComponent,
                            reason: stderr.isEmpty ? "sips exited \(code)" : stderr))
                }
            } catch {
                result.failures.append(.init(name: url.lastPathComponent, reason: error.localizedDescription))
            }
        }
        return result
    }

    static func outputURL(for url: URL, options: Options) -> URL {
        let dir = url.deletingLastPathComponent()
        let ext = options.format?.fileExtension ?? url.pathExtension
        var base = url.deletingPathExtension().lastPathComponent
        // A pure resize keeps the format, so distinguish it from the original by name.
        if options.maxDimension != nil && options.format == nil { base += " resized" }
        return unique(dir.appendingPathComponent(ext.isEmpty ? base : "\(base).\(ext)"))
    }

    private static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            let candidate = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}
