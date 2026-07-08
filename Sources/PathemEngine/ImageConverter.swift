import CoreGraphics
import Foundation
import ImageIO

/// Batch image conversion and resizing via `sips`, the built-in macOS image tool, run
/// out-of-process (per the architecture rule that heavy/third-party work never runs inline
/// in the FDA process), plus optional metadata stripping via ImageIO. Writes new files
/// next to the originals, never overwriting them.
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
        /// Drop EXIF/GPS/other metadata (privacy) by re-encoding without it.
        public var stripMetadata: Bool
        public init(format: Format? = nil, maxDimension: Int? = nil, stripMetadata: Bool = false) {
            self.format = format
            self.maxDimension = maxDimension
            self.stripMetadata = stripMetadata
        }
        public var isNoOp: Bool { format == nil && maxDimension == nil && !stripMetadata }
        var needsSips: Bool { format != nil || maxDimension != nil }
    }

    public struct Result: Sendable, Equatable {
        public var outputs: [URL] = []
        public var failures: [FileOperations.Failure] = []
        public init() {}
    }

    /// Rotate each image in place by `clockwiseDegrees` (a multiple of 90) via `sips -r`. Used by
    /// the Rotate Left / Rotate Right quick actions. A per-item failure is recorded and the batch
    /// continues; rotating the opposite way is the manual undo (sips re-encodes, so it isn't
    /// registered with the undo history).
    public static func rotate(_ urls: [URL], clockwiseDegrees: Int) async -> Result {
        var result = Result()
        let degrees = ((clockwiseDegrees % 360) + 360) % 360  // sips wants a positive 0…359 value
        guard degrees != 0 else { return result }
        for url in urls {
            do {
                let (_, code, stderr) = try await RemoteRunner.run("/usr/bin/sips", ["-r", "\(degrees)", url.path])
                if code == 0 {
                    result.outputs.append(url)
                } else {
                    result.failures.append(
                        .init(name: url.lastPathComponent, reason: stderr.isEmpty ? "sips exited \(code)" : stderr))
                }
            } catch {
                result.failures.append(.init(name: url.lastPathComponent, reason: error.localizedDescription))
            }
        }
        return result
    }

    /// Convert/resize each image. Sequential (each `sips` call is quick), off-main via the
    /// subprocess runner. A per-item failure is recorded and the batch continues.
    public static func process(_ urls: [URL], options: Options) async -> Result {
        var result = Result()
        guard !options.isNoOp else { return result }
        let fm = FileManager.default
        for url in urls {
            let output = outputURL(for: url, options: options)
            do {
                if options.needsSips {
                    var args: [String] = []
                    if let format = options.format { args += ["-s", "format", format.sipsName] }
                    if let max = options.maxDimension { args += ["-Z", "\(max)"] }
                    args += [url.path, "--out", output.path]
                    let (_, code, stderr) = try await RemoteRunner.run("/usr/bin/sips", args)
                    guard code == 0 else {
                        result.failures.append(
                            .init(
                                name: url.lastPathComponent,
                                reason: stderr.isEmpty ? "sips exited \(code)" : stderr))
                        continue
                    }
                } else {
                    // Strip-only: start from a copy so the original is untouched.
                    try fm.copyItem(at: url, to: output)
                }
                if options.stripMetadata, !stripMetadata(at: output) {
                    result.failures.append(
                        .init(name: url.lastPathComponent, reason: "couldn't strip metadata"))
                    try? fm.removeItem(at: output)
                    continue
                }
                result.outputs.append(output)
            } catch {
                result.failures.append(.init(name: url.lastPathComponent, reason: error.localizedDescription))
            }
        }
        return result
    }

    /// Re-encode the image at `url` without carrying over EXIF/GPS/other metadata (ImageIO).
    static func stripMetadata(at url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let type = CGImageSourceGetType(source),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return false }
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".pathem-strip-\(UUID().uuidString)")
        guard let destination = CGImageDestinationCreateWithURL(temp as CFURL, type, 1, nil) else {
            return false
        }
        // Adding the image with no properties dictionary drops the source metadata.
        CGImageDestinationAddImage(destination, image, [:] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: temp)
            return false
        }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            return true
        } catch {
            try? FileManager.default.removeItem(at: temp)
            return false
        }
    }

    static func outputURL(for url: URL, options: Options) -> URL {
        let dir = url.deletingLastPathComponent()
        let ext = options.format?.fileExtension ?? url.pathExtension
        var base = url.deletingPathExtension().lastPathComponent
        // Same-format operations keep the extension, so distinguish them from the original.
        if options.format == nil {
            if options.maxDimension != nil { base += " resized" } else if options.stripMetadata { base += " clean" }
        }
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
