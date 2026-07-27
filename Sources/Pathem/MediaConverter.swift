import AVFoundation
import Foundation

/// Transcodes a video/audio file to a new format with AVFoundation, completing the "conversion hub"
/// (image conversion already lives in ImageConverter). Two reliable, popular targets: extract the
/// audio track as M4A, or transcode a video to MP4 (H.264). Runs off the main thread.
enum MediaConverter {
    enum Target: Sendable {
        case mp4  // transcode to an H.264 MP4
        case m4aAudio  // extract the audio track as M4A

        var preset: String {
            switch self {
            case .mp4: AVAssetExportPresetHighestQuality
            case .m4aAudio: AVAssetExportPresetAppleM4A
            }
        }
        var fileType: AVFileType {
            switch self {
            case .mp4: .mp4
            case .m4aAudio: .m4a
            }
        }
        var fileExtension: String {
            switch self {
            case .mp4: "mp4"
            case .m4aAudio: "m4a"
            }
        }
    }

    struct ConversionError: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// Transcode `url` to `target`, writing a non-colliding file into `directory`; returns the URL.
    static func convert(_ url: URL, to target: Target, into directory: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: target.preset) else {
            throw ConversionError(reason: L("media.convertNoSession", "This file can’t be converted with that preset."))
        }
        let name = url.deletingPathExtension().lastPathComponent + "." + target.fileExtension
        let output = PhotoLibrary.uniqueURL(in: directory, name: name)
        try await session.export(to: output, as: target.fileType)
        return output
    }
}
