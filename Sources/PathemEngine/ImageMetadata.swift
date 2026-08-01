import CoreGraphics
import Foundation
import ImageIO

/// Reads and losslessly edits the EXIF/IPTC/TIFF fields people actually manage:
/// the capture date, a caption/description, the author, a copyright notice, and
/// keywords. Writes copy the already-compressed image data via
/// `CGImageDestinationAddImageFromSource` (no pixel re-encode, no quality loss) and
/// only rewrite the metadata dictionaries, then atomically replace the original.
/// Pure ImageIO, no AppKit, so it's unit-tested and runs off-main.
public enum ImageMetadata {
    /// The editable fields, as currently stored (nil / empty = absent).
    public struct Fields: Sendable, Equatable {
        public var dateTaken: Date?
        public var caption: String?
        public var author: String?
        public var copyright: String?
        public var keywords: [String]
        public init(
            dateTaken: Date? = nil, caption: String? = nil, author: String? = nil,
            copyright: String? = nil, keywords: [String] = []
        ) {
            self.dateTaken = dateTaken
            self.caption = caption
            self.author = author
            self.copyright = copyright
            self.keywords = keywords
        }
    }

    /// A per-field intent: leave it as-is, set a new value, or clear it. Bulk edits
    /// carry one of these per field so untouched fields are never disturbed across a
    /// mixed selection.
    public enum FieldEdit<Value: Sendable & Equatable>: Sendable, Equatable {
        case unchanged
        case set(Value)
        case cleared
    }

    public struct Edit: Sendable, Equatable {
        public var dateTaken: FieldEdit<Date> = .unchanged
        public var caption: FieldEdit<String> = .unchanged
        public var author: FieldEdit<String> = .unchanged
        public var copyright: FieldEdit<String> = .unchanged
        public var keywords: FieldEdit<[String]> = .unchanged
        public init() {}

        public var isEmpty: Bool {
            dateTaken == .unchanged && caption == .unchanged && author == .unchanged
                && copyright == .unchanged && keywords == .unchanged
        }
    }

    public struct MetadataError: LocalizedError {
        public let reason: String
        public var errorDescription: String? { reason }
        public init(reason: String) { self.reason = reason }
    }

    /// EXIF stores dates as "yyyy:MM:dd HH:mm:ss" in no particular timezone; read and
    /// write use the same fixed formatter so a round-trip is stable.
    private static let exifDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    /// The current metadata of the image at `url` (best-effort; missing fields come
    /// back nil/empty).
    public static func read(_ url: URL) -> Fields {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return Fields() }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any]

        let dateString = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String)
        let caption = (iptc?[kCGImagePropertyIPTCCaptionAbstract] as? String)
            ?? (tiff?[kCGImagePropertyTIFFImageDescription] as? String)
        let author = firstString(iptc?[kCGImagePropertyIPTCByline])
            ?? (tiff?[kCGImagePropertyTIFFArtist] as? String)
        let copyright = (iptc?[kCGImagePropertyIPTCCopyrightNotice] as? String)
            ?? (tiff?[kCGImagePropertyTIFFCopyright] as? String)
        let keywords = (iptc?[kCGImagePropertyIPTCKeywords] as? [String]) ?? []

        return Fields(
            dateTaken: dateString.flatMap { exifDate.date(from: $0) },
            caption: nonEmpty(caption), author: nonEmpty(author), copyright: nonEmpty(copyright),
            keywords: keywords)
    }

    /// Apply `edit` to the image at `url`, losslessly and in place. Returns false for
    /// an empty edit (nothing written); true once the metadata was rewritten.
    @discardableResult
    public static func apply(_ edit: Edit, to url: URL) throws -> Bool {
        guard !edit.isEmpty else { return false }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let type = CGImageSourceGetType(source)
        else { throw MetadataError(reason: "Couldn’t read the image.") }

        var props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        var exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        var iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]

        applyString(edit.caption, iptc: kCGImagePropertyIPTCCaptionAbstract, into: &iptc,
            tiff: kCGImagePropertyTIFFImageDescription, into: &tiff)
        applyString(edit.author, iptc: kCGImagePropertyIPTCByline, into: &iptc,
            tiff: kCGImagePropertyTIFFArtist, into: &tiff)
        applyString(edit.copyright, iptc: kCGImagePropertyIPTCCopyrightNotice, into: &iptc,
            tiff: kCGImagePropertyTIFFCopyright, into: &tiff)

        switch edit.keywords {
        case .unchanged: break
        case .set(let words): iptc[kCGImagePropertyIPTCKeywords] = words.isEmpty ? kCFNull : words
        case .cleared: iptc[kCGImagePropertyIPTCKeywords] = kCFNull
        }

        switch edit.dateTaken {
        case .unchanged: break
        case .set(let date):
            let text = exifDate.string(from: date)
            exif[kCGImagePropertyExifDateTimeOriginal] = text
            exif[kCGImagePropertyExifDateTimeDigitized] = text
            tiff[kCGImagePropertyTIFFDateTime] = text
        case .cleared:
            exif[kCGImagePropertyExifDateTimeOriginal] = kCFNull
            exif[kCGImagePropertyExifDateTimeDigitized] = kCFNull
            tiff[kCGImagePropertyTIFFDateTime] = kCFNull
        }

        props[kCGImagePropertyExifDictionary] = exif.isEmpty ? nil : exif
        props[kCGImagePropertyTIFFDictionary] = tiff.isEmpty ? nil : tiff
        props[kCGImagePropertyIPTCDictionary] = iptc.isEmpty ? nil : iptc

        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".pathem-meta-\(UUID().uuidString).tmp")
        let count = CGImageSourceGetCount(source)
        guard let dest = CGImageDestinationCreateWithURL(temp as CFURL, type, count, nil) else {
            throw MetadataError(reason: "Couldn’t prepare the image.")
        }
        // Carry the container-level properties (e.g. an animated GIF's loop count) so a metadata
        // edit doesn't drop them; per-image properties are set below.
        if let container = CGImageSourceCopyProperties(source, nil) {
            CGImageDestinationSetProperties(dest, container)
        }
        // Copy the compressed image data verbatim (lossless); only image 0 takes the
        // edited properties, other frames keep their own so multi-image files survive.
        for index in 0..<count {
            let perImage: CFDictionary? =
                index == 0 ? props as CFDictionary : CGImageSourceCopyPropertiesAtIndex(source, index, nil)
            CGImageDestinationAddImageFromSource(dest, source, index, perImage)
        }
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: temp)
            throw MetadataError(reason: "Couldn’t write the image metadata.")
        }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)  // don't leak the temp beside the original
            throw error
        }
        return true
    }

    // MARK: Helpers

    private static func applyString(
        _ edit: FieldEdit<String>, iptc iptcKey: CFString, into iptc: inout [CFString: Any],
        tiff tiffKey: CFString, into tiff: inout [CFString: Any]
    ) {
        switch edit {
        case .unchanged:
            break
        case .set(let value):
            iptc[iptcKey] = value
            tiff[tiffKey] = value
        case .cleared:
            // ImageIO deletes a property when its value is kCFNull; omitting the key
            // would instead leave the source's original value (AddImageFromSource merges).
            iptc[iptcKey] = kCFNull
            tiff[tiffKey] = kCFNull
        }
    }

    /// IPTC byline can be a string or an array of strings; take the first meaningful one.
    private static func firstString(_ any: Any?) -> String? {
        if let s = any as? String { return nonEmpty(s) }
        if let list = any as? [String] { return nonEmpty(list.first) }
        return nil
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }
}
