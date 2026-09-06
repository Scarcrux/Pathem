import CoreImage
import Foundation
import Vision

/// Isolates the foreground subject of a photo and writes it as a transparent-background PNG, using
/// the same on-device Vision engine Photos/Preview use for "lift subject" (`VNGenerateForegroundInstance
/// MaskRequest`, macOS 14+). Pure image processing (Vision + Core Image), no AppKit, so it's testable
/// and runs off the main thread.
public enum SubjectLift {
    /// No foreground subject could be found in the image (or the input wasn't a decodable image).
    public struct NoSubjectFound: LocalizedError {
        public var errorDescription: String? { "Couldn’t find a subject to lift from this image." }
    }

    /// Lift the foreground subject(s) from the image at `source` and write a transparent PNG cropped to
    /// the subject to `destination`. Throws `NoSubjectFound` when there's no subject (or the image can't
    /// be read). Runs synchronously; call it off the main thread.
    public static func removeBackground(from source: URL, to destination: URL) throws {
        let handler = VNImageRequestHandler(url: source, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        do {
            try handler.perform([request])
        } catch {
            throw NoSubjectFound()  // undecodable image or no vision result
        }
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw NoSubjectFound()
        }
        let masked = try observation.generateMaskedImage(
            ofInstances: observation.allInstances, from: handler, croppedToInstancesExtent: true)
        try writePNG(CIImage(cvPixelBuffer: masked), to: destination)
    }

    /// The suggested output name for a cutout of `name`: its base name + " Cutout.png".
    public static func cutoutName(for name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        return "\(base) Cutout.png"
    }

    // CIContext is documented as thread-safe for rendering, so a shared static is safe. The
    // macOS 26 SDK marks it Sendable; older SDKs (the CI runner) do not, so spell the safety
    // out explicitly to compile on both.
    private nonisolated(unsafe) static let ciContext = CIContext()

    private static func writePNG(_ image: CIImage, to destination: URL) throws {
        let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        try ciContext.writePNGRepresentation(of: image, to: destination, format: .RGBA8, colorSpace: colorSpace)
    }
}
