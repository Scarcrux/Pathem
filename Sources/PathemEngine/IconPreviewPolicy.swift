import Foundation
import UniformTypeIdentifiers

/// Decides whether a file's icon may be replaced by a QuickLook preview, and by which kind.
///
/// Without a theme the file views ask QuickLook for every file, which at list-row sizes
/// returns the macOS document icon. With themed file icons that system icon would paint
/// over the theme's own icon, so a themed file only gets a preview when QuickLook can show
/// its real content (a picture, a video frame, a PDF page). Every view that swaps an icon
/// for a preview asks here, so the views cannot drift apart.
public enum IconPreviewPolicy {
    public enum Kind: Equatable, Sendable {
        /// Keep the icon the view already has; request nothing.
        case none
        /// Request the content thumbnail only, at every size. Never the system icon.
        case contentThumbnail
        /// The unthemed behavior: the system icon representation at list-row sizes
        /// and the content thumbnail above them.
        case systemDefault
    }

    /// `themed` is true when the active theme supplies this file's icon (a built-in file
    /// icon style other than System, or theme artwork for the file's category).
    public static func kind(for type: UTType?, themed: Bool) -> Kind {
        guard themed else { return .systemDefault }
        guard let type else { return .none }
        // Video is matched as .movie and .video, not .audiovisualContent, which would also
        // take in plain audio: an audio file has no frame to show in place of a themed icon.
        let showsContent =
            type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .video)
            || type.conforms(to: .pdf)
        return showsContent ? .contentThumbnail : .none
    }

    /// The same decision from a file name, by its extension.
    public static func kind(forFileNamed name: String, themed: Bool) -> Kind {
        let ext = (name as NSString).pathExtension
        return kind(for: ext.isEmpty ? nil : UTType(filenameExtension: ext), themed: themed)
    }
}
