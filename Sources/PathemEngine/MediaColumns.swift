import AVFoundation
import AudioToolbox
import CoreGraphics
import CoreMedia
import CoreServices
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Values for the media metadata list columns: dimensions, date taken, camera, duration,
/// artist, album, pages, codec and bit rate.
///
/// Spotlight (MDItem) answers first because it needs no decoding. Anything Spotlight does not
/// know (an unindexed volume, a fresh download) is read lazily with ImageIO, AVFoundation or
/// CoreGraphics, header-only. Reads are cached by path, size and modification time, so scrolling
/// back over a row never touches disk again and an edited file is re-read. Pure Foundation-level
/// frameworks (no AppKit), off-main by contract.
public enum MediaColumns {
    /// What one file reports. Every field is optional: absent means "this file does not say".
    public struct Attributes: Sendable, Hashable {
        public var width: Int?
        public var height: Int?
        public var dateTaken: Date?
        public var camera: String?
        public var duration: TimeInterval?
        public var artist: String?
        public var album: String?
        public var pages: Int?
        public var codec: String?
        /// Bits per second.
        public var bitRate: Int?

        public init(
            width: Int? = nil, height: Int? = nil, dateTaken: Date? = nil, camera: String? = nil,
            duration: TimeInterval? = nil, artist: String? = nil, album: String? = nil,
            pages: Int? = nil, codec: String? = nil, bitRate: Int? = nil
        ) {
            self.width = width
            self.height = height
            self.dateTaken = dateTaken
            self.camera = camera
            self.duration = duration
            self.artist = artist
            self.album = album
            self.pages = pages
            self.codec = codec
            self.bitRate = bitRate
        }

        /// "W × H", or nil when either side is unknown.
        public var dimensionsLabel: String? {
            guard let width, let height else { return nil }
            return "\(width) × \(height)"
        }

        /// Pixel area, the key the Dimensions column sorts on.
        public var pixelArea: Int? {
            guard let width, let height, width > 0, height > 0 else { return nil }
            let (area, overflow) = width.multipliedReportingOverflow(by: height)
            return overflow ? nil : area
        }
    }

    /// Which fields a pass should compute, so a pass only does the work that is on screen.
    public struct Fields: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let dimensions = Fields(rawValue: 1 << 0)
        public static let dateTaken = Fields(rawValue: 1 << 1)
        public static let camera = Fields(rawValue: 1 << 2)
        public static let duration = Fields(rawValue: 1 << 3)
        public static let artist = Fields(rawValue: 1 << 4)
        public static let album = Fields(rawValue: 1 << 5)
        public static let pages = Fields(rawValue: 1 << 6)
        public static let codec = Fields(rawValue: 1 << 7)
        public static let bitRate = Fields(rawValue: 1 << 8)
        public static let all: Fields = [
            .dimensions, .dateTaken, .camera, .duration, .artist, .album, .pages, .codec, .bitRate,
        ]

        /// The field a sort key needs, or nil when the key is not a media column.
        public init?(sortKey: ViewFormat.SortKey) {
            switch sortKey {
            case .dimensions: self = .dimensions
            case .dateTaken: self = .dateTaken
            case .camera: self = .camera
            case .duration: self = .duration
            case .artist: self = .artist
            case .album: self = .album
            case .pages: self = .pages
            case .codec: self = .codec
            case .bitRate: self = .bitRate
            default: return nil
            }
        }
    }

    public enum Source: Sendable {
        /// Spotlight first, then decode what it did not know (the normal path).
        case spotlightThenFallback
        /// Skip Spotlight entirely. Deterministic, used by tests.
        case fallbackOnly
    }

    // MARK: Extraction

    public static func extract(
        _ url: URL, fields: Fields, source: Source = .spotlightThenFallback
    ) -> Attributes {
        extractResult(url, fields: fields, source: source).attributes
    }

    private static func extractResult(
        _ url: URL, fields: Fields, source: Source
    ) -> (attributes: Attributes, complete: Bool) {
        var out = Attributes()
        guard !fields.isEmpty else { return (out, true) }
        let type = UTType(filenameExtension: url.pathExtension)
        if source == .spotlightThenFallback { fillFromSpotlight(&out, url, fields, type) }
        let missing = missingFields(out, fields)
        let complete = missing.isEmpty || fillFromDecoders(&out, url, missing, type)
        return (out, complete)
    }

    private static func missingFields(_ a: Attributes, _ wanted: Fields) -> Fields {
        var m: Fields = []
        if wanted.contains(.dimensions), a.width == nil || a.height == nil { m.insert(.dimensions) }
        if wanted.contains(.dateTaken), a.dateTaken == nil { m.insert(.dateTaken) }
        if wanted.contains(.camera), a.camera == nil { m.insert(.camera) }
        if wanted.contains(.duration), a.duration == nil { m.insert(.duration) }
        if wanted.contains(.artist), a.artist == nil { m.insert(.artist) }
        if wanted.contains(.album), a.album == nil { m.insert(.album) }
        if wanted.contains(.pages), a.pages == nil { m.insert(.pages) }
        if wanted.contains(.codec), a.codec == nil { m.insert(.codec) }
        if wanted.contains(.bitRate), a.bitRate == nil { m.insert(.bitRate) }
        return m
    }

    private static func fillFromSpotlight(
        _ out: inout Attributes, _ url: URL, _ fields: Fields, _ type: UTType?
    ) {
        guard let item = MDItemCreate(kCFAllocatorDefault, url.path as CFString) else { return }
        func attr(_ name: CFString) -> Any? { MDItemCopyAttribute(item, name) }
        func text(_ name: CFString) -> String? {
            let value = attr(name)
            let s = (value as? String) ?? (value as? [String])?.joined(separator: ", ")
            guard let trimmed = s?.trimmingCharacters(in: .whitespacesAndNewlines),
                !trimmed.isEmpty
            else { return nil }
            return trimmed
        }
        if fields.contains(.dimensions) {
            out.width = (attr(kMDItemPixelWidth) as? NSNumber)?.intValue
            out.height = (attr(kMDItemPixelHeight) as? NSNumber)?.intValue
            if out.width == nil || out.height == nil {
                out.width = nil
                out.height = nil
            }
        }
        // A content creation date means "taken" only for photos and video; for a document it is
        // just when the file was made, which the Date Created column already shows.
        if fields.contains(.dateTaken),
            type?.conforms(to: .image) == true || type?.conforms(to: .audiovisualContent) == true
        {
            out.dateTaken = attr(kMDItemContentCreationDate) as? Date
        }
        if fields.contains(.camera) {
            out.camera = cameraLabel(
                make: text(kMDItemAcquisitionMake), model: text(kMDItemAcquisitionModel))
        }
        if fields.contains(.duration) {
            if let seconds = (attr(kMDItemDurationSeconds) as? NSNumber)?.doubleValue,
                seconds.isFinite, seconds > 0
            {
                out.duration = seconds
            }
        }
        if fields.contains(.artist) { out.artist = text(kMDItemAuthors) }
        if fields.contains(.album) { out.album = text(kMDItemAlbum) }
        if fields.contains(.pages) {
            out.pages = (attr(kMDItemNumberOfPages) as? NSNumber)?.intValue
        }
        if fields.contains(.codec) { out.codec = text(kMDItemCodecs) }
        if fields.contains(.bitRate) {
            let rate =
                (attr(kMDItemTotalBitRate) as? NSNumber) ?? (attr(kMDItemAudioBitRate) as? NSNumber)
            out.bitRate = rate.map { $0.intValue }.flatMap { $0 > 0 ? $0 : nil }
        }
    }

    private static func fillFromDecoders(
        _ out: inout Attributes, _ url: URL, _ missing: Fields, _ type: UTType?
    ) -> Bool {
        guard !Task.isCancelled else { return false }
        let isImage = type?.conforms(to: .image) == true
        let isPDF = type?.conforms(to: .pdf) == true
        let isTimed = type?.conforms(to: .audiovisualContent) == true
        if isImage {
            fillFromImageIO(&out, url, missing)
        } else if isPDF {
            if missing.contains(.pages), let doc = CGPDFDocument(url as CFURL),
                !doc.isEncrypted
                    || doc.isUnlocked
            {
                let n = doc.numberOfPages
                if n > 0 { out.pages = n }
            }
        } else if isTimed {
            // The WAVE container exposes PCM format and duration directly. AVAsset may
            // report a zero estimated bit rate or time out while its worker is queued.
            if type?.conforms(to: .wav) == true {
                fillFromWaveHeader(&out, url, missing)
            }
            let remaining = missingFields(out, missing)
            return remaining.isEmpty || fillFromAVFoundation(&out, url, remaining)
        }
        return true
    }

    private static func fillFromWaveHeader(_ out: inout Attributes, _ url: URL, _ fields: Fields) {
        guard !fields.intersection([.duration, .codec, .bitRate]).isEmpty else { return }
        var opened: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, kAudioFileWAVEType, &opened) == noErr,
            let file = opened
        else { return }
        defer { AudioFileClose(file) }
        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout.size(ofValue: format))
        guard
            AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &formatSize, &format) == noErr
        else { return }
        if fields.contains(.codec) {
            out.codec = codecName(fourCC: fourCCString(format.mFormatID))
        }
        if fields.contains(.bitRate), format.mFormatID == kAudioFormatLinearPCM {
            let bitsPerSecond = format.mSampleRate * Double(format.mBytesPerFrame) * 8
            if bitsPerSecond.isFinite, bitsPerSecond > 0 {
                out.bitRate = Int(exactly: bitsPerSecond.rounded())
            }
        }
        if fields.contains(.duration) {
            var seconds: Double = 0
            var size = UInt32(MemoryLayout.size(ofValue: seconds))
            if AudioFileGetProperty(file, kAudioFilePropertyEstimatedDuration, &size, &seconds)
                == noErr,
                seconds.isFinite, seconds > 0
            {
                out.duration = seconds
            }
        }
    }

    private static func fillFromImageIO(_ out: inout Attributes, _ url: URL, _ missing: Fields) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return }
        if missing.contains(.dimensions),
            let w = props[kCGImagePropertyPixelWidth] as? Int,
            let h = props[kCGImagePropertyPixelHeight] as? Int
        {
            out.width = w
            out.height = h
        }
        if missing.contains(.dateTaken),
            let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
            let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        {
            out.dateTaken = exifDate(raw)
        }
        if missing.contains(.camera),
            let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        {
            out.camera = cameraLabel(
                make: tiff[kCGImagePropertyTIFFMake] as? String,
                model: tiff[kCGImagePropertyTIFFModel] as? String)
        }
    }

    /// EXIF "yyyy:MM:dd HH:mm:ss" carries no zone; read it as local wall-clock time.
    static func exifDate(_ raw: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.date(from: raw)
    }

    private static func fillFromAVFoundation(
        _ out: inout Attributes, _ url: URL, _ missing: Fields
    ) -> Bool {
        let original = out
        guard
            let loaded = blocking({
                let asset = AVURLAsset(url: url)
                var a = original
                if missing.contains(.duration), let d = try? await asset.load(.duration),
                    d.isNumeric, d.seconds > 0
                {
                    a.duration = d.seconds
                }
                if missing.contains(.artist) || missing.contains(.album) {
                    let common = (try? await asset.load(.commonMetadata)) ?? []
                    func string(_ id: AVMetadataIdentifier) async -> String? {
                        guard
                            let item = AVMetadataItem.metadataItems(
                                from: common, filteredByIdentifier: id
                            )
                            .first
                        else { return nil }
                        let s = try? await item.load(.stringValue)
                        let t = s?.trimmingCharacters(in: .whitespacesAndNewlines)
                        return t?.isEmpty == false ? t : nil
                    }
                    if missing.contains(.artist) {
                        a.artist = await string(.commonIdentifierArtist)
                    }
                    if missing.contains(.album) {
                        a.album = await string(.commonIdentifierAlbumName)
                    }
                }
                if missing.contains(.codec) || missing.contains(.bitRate)
                    || missing.contains(.dimensions)
                {
                    let tracks = (try? await asset.load(.tracks)) ?? []
                    var codecs: [String] = []
                    var rate: Double = 0
                    for track in tracks {
                        var pcmRate: Double?
                        if let formats = try? await track.load(.formatDescriptions),
                            let f = formats.first
                        {
                            let code = CMFormatDescriptionGetMediaSubType(f)
                            let name = codecName(fourCC: fourCCString(code))
                            if !codecs.contains(name) { codecs.append(name) }
                            if missing.contains(.bitRate), code == kAudioFormatLinearPCM,
                                let format = CMAudioFormatDescriptionGetStreamBasicDescription(f)?
                                    .pointee
                            {
                                let streams =
                                    format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
                                    ? 1 : Double(format.mChannelsPerFrame)
                                pcmRate =
                                    format.mSampleRate * Double(format.mBytesPerFrame) * streams * 8
                            }
                        }
                        if missing.contains(.bitRate) {
                            if let estimate = try? await track.load(.estimatedDataRate),
                                estimate.isFinite, estimate > 0
                            {
                                rate += Double(estimate)
                            } else if let pcmRate, pcmRate.isFinite {
                                rate += pcmRate
                            }
                        }
                        if missing.contains(.dimensions), a.width == nil,
                            track.mediaType == .video,
                            let size = try? await track.load(.naturalSize),
                            let width = Int(exactly: size.width.rounded()), width > 0,
                            let height = Int(exactly: size.height.rounded()), height > 0
                        {
                            a.width = width
                            a.height = height
                        }
                    }
                    if missing.contains(.codec), !codecs.isEmpty {
                        a.codec = codecs.joined(separator: ", ")
                    }
                    if missing.contains(.bitRate), rate > 0 {
                        a.bitRate = Int(exactly: rate.rounded())
                    }
                }
                return a
            })
        else { return false }
        out = loaded
        return true
    }

    private final class LoadResult: @unchecked Sendable {
        private let lock = NSLock()
        private var attributes: Attributes?
        func store(_ value: Attributes) { lock.withLock { attributes = value } }
        func read() -> Attributes? { lock.withLock { attributes } }
    }

    private static let avLoadSlots = DispatchSemaphore(value: 4)

    /// AVFoundation can stall on an unavailable asset. Bound the caller's wait
    /// and keep each worker's slot until it actually exits.
    private static func blocking(
        _ work: @escaping @Sendable () async -> Attributes
    ) -> Attributes? {
        guard !Task.isCancelled, avLoadSlots.wait(timeout: .now()) == .success else { return nil }
        let result = LoadResult()
        let done = DispatchSemaphore(value: 0)
        let worker = Task.detached {
            defer {
                avLoadSlots.signal()
                done.signal()
            }
            result.store(await work())
        }
        guard done.wait(timeout: .now() + 2) == .success, !Task.isCancelled else {
            worker.cancel()
            return nil
        }
        return result.read()
    }

    // MARK: Labels

    public static func durationLabel(_ seconds: TimeInterval) -> String {
        guard let total = Int(exactly: seconds.rounded()), total >= 0 else { return "—" }
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "320 kbps" from bits per second; nil for zero or negative.
    public static func bitRateLabel(_ bitsPerSecond: Int) -> String? {
        guard bitsPerSecond > 0 else { return nil }
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        let kbps = Int((Double(bitsPerSecond) / 1000).rounded())
        return "\(f.string(from: NSNumber(value: kbps)) ?? "\(kbps)") kbps"
    }

    /// Joins make and model without repeating the make ("Canon" + "Canon EOS R5").
    public static func cameraLabel(make: String?, model: String?) -> String? {
        let mk = make?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let md = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if md.isEmpty { return mk.isEmpty ? nil : mk }
        if mk.isEmpty || md.lowercased().hasPrefix(mk.lowercased()) { return md }
        return "\(mk) \(md)"
    }

    static func fourCCString(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
        return String(bytes: bytes, encoding: .macOSRoman) ?? "????"
    }

    /// A readable name for common codec four-character codes; unknown codes pass through.
    public static func codecName(fourCC: String) -> String {
        switch fourCC {
        case "aac ", "mp4a": return "AAC"
        case "lpcm", "sowt", "twos", "in24", "in32", "fl32", "fl64": return "PCM"
        case ".mp3", "mp3 ": return "MP3"
        case "alac": return "ALAC"
        case "flac": return "FLAC"
        case "ac-3": return "AC-3"
        case "ec-3": return "E-AC-3"
        case "opus": return "Opus"
        case "avc1", "avc3": return "H.264"
        case "hvc1", "hev1": return "HEVC"
        case "av01": return "AV1"
        case "vp09": return "VP9"
        case "apcn", "apch", "apcs", "apco", "ap4h": return "ProRes"
        case "jpeg", "mjpa": return "Motion JPEG"
        default: return fourCC.trimmingCharacters(in: .whitespaces)
        }
    }

    // MARK: Cache

    /// Identity of a file's content for caching: a change in path, size or mtime is a new key.
    public struct CacheKey: Sendable, Hashable {
        public let path: String
        public let size: Int64
        /// Modification time in nanoseconds since the epoch.
        public let modified: Int64

        public init(path: String, size: Int64, modified: Int64) {
            self.path = path
            self.size = size
            self.modified = modified
        }

        /// Stats the file; nil when it cannot be read.
        public init?(url: URL) {
            var st = stat()
            guard stat(url.path, &st) == 0 else { return nil }
            self.init(
                path: url.path, size: Int64(st.st_size),
                modified: Int64(st.st_mtimespec.tv_sec) * 1_000_000_000
                    + Int64(st.st_mtimespec.tv_nsec))
        }
    }

    /// A bounded, thread-safe memo of extraction results. When full it drops everything and
    /// starts over: the working set is the visible window, so a cheap reset beats LRU bookkeeping.
    public final class Cache: @unchecked Sendable {
        public static let shared = Cache(capacity: 8192)

        private struct Slot {
            var fields: Fields
            var attributes: Attributes
        }
        private let lock = NSLock()
        private var slots: [CacheKey: Slot] = [:]
        private let capacity: Int
        private var extractionCount = 0

        public init(capacity: Int) { self.capacity = max(1, capacity) }

        /// Number of real disk reads performed (cache misses), for tests and diagnostics.
        public var extractions: Int { lock.withLock { extractionCount } }
        public var count: Int { lock.withLock { slots.count } }

        public func values(
            for url: URL, fields: Fields, source: Source = .spotlightThenFallback
        ) -> Attributes {
            guard let key = CacheKey(url: url) else { return Attributes() }
            let prior: Slot? = lock.withLock {
                if let hit = slots[key], hit.fields.isSuperset(of: fields) { return hit }
                return slots[key]
            }
            if let prior, prior.fields.isSuperset(of: fields) { return prior.attributes }
            // Widen: read only the fields the cached slot lacks, then merge.
            let need = prior.map { fields.subtracting($0.fields) } ?? fields
            let fresh = MediaColumns.extractResult(url, fields: need, source: source)
            let combined = merged(prior?.attributes, fresh.attributes)
            // A canceled or timed-out pass can be retried when the asset is available.
            guard !Task.isCancelled, fresh.complete else { return combined }
            lock.withLock {
                extractionCount += 1
                if slots.count >= capacity { slots.removeAll(keepingCapacity: true) }
                slots[key] = Slot(fields: fields.union(prior?.fields ?? []), attributes: combined)
            }
            return combined
        }

        private func merged(_ old: Attributes?, _ new: Attributes) -> Attributes {
            guard var a = old else { return new }
            a.width = new.width ?? a.width
            a.height = new.height ?? a.height
            a.dateTaken = new.dateTaken ?? a.dateTaken
            a.camera = new.camera ?? a.camera
            a.duration = new.duration ?? a.duration
            a.artist = new.artist ?? a.artist
            a.album = new.album ?? a.album
            a.pages = new.pages ?? a.pages
            a.codec = new.codec ?? a.codec
            a.bitRate = new.bitRate ?? a.bitRate
            return a
        }
    }
}
