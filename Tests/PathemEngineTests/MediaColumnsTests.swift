import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers

@testable import PathemEngine

@Suite struct MediaColumnsTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pathem-media-cols-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A JPEG with known size, EXIF capture date and camera make/model.
    private func writeJPEG(_ url: URL, width: Int, height: Int) throws {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let props: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2021:06:05 14:30:00"
            ],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Fujifilm",
                kCGImagePropertyTIFFModel: "X100V",
            ],
        ]
        let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, props as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
    }

    /// A mono 16-bit 8 kHz PCM WAV of exactly `seconds` seconds (128 kbps).
    private func writeWAV(_ url: URL, seconds: Int) throws {
        let rate = 8000
        let dataBytes = rate * 2 * seconds
        var d = Data()
        func u32(_ v: Int) {
            withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) }
        }
        func u16(_ v: Int) {
            withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) }
        }
        d.append(contentsOf: Array("RIFF".utf8))
        u32(36 + dataBytes)
        d.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16)
        u16(1)
        u16(1)
        u32(rate)
        u32(rate * 2)
        u16(2)
        u16(16)
        d.append(contentsOf: Array("data".utf8))
        u32(dataBytes)
        d.append(Data(count: dataBytes))
        try d.write(to: url)
    }

    private func writePDF(_ url: URL, pages: Int) throws {
        var box = CGRect(x: 0, y: 0, width: 200, height: 300)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        for _ in 0..<pages {
            ctx.beginPDFPage(nil)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    @Test func imageIOFallbackReadsDimensionsDateAndCamera() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let jpg = dir.appendingPathComponent("shot.jpg")
        try writeJPEG(jpg, width: 64, height: 48)
        let v = MediaColumns.extract(
            jpg, fields: [.dimensions, .dateTaken, .camera], source: .fallbackOnly)
        #expect(v.width == 64 && v.height == 48)
        #expect(v.camera == "Fujifilm X100V")
        let parts = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: try #require(v.dateTaken))
        #expect(
            parts.year == 2021 && parts.month == 6 && parts.day == 5 && parts.hour == 14
                && parts.minute == 30)
        #expect(v.duration == nil && v.pages == nil)  // not requested, not read
    }

    @Test func audioFallbackReadsDurationCodecAndBitRate() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("tone.wav")
        try writeWAV(wav, seconds: 3)
        let v = MediaColumns.extract(
            wav, fields: [.duration, .codec, .bitRate], source: .fallbackOnly)
        #expect(abs((v.duration ?? 0) - 3) < 0.05)
        #expect(v.codec == "PCM")
        #expect(abs((v.bitRate ?? 0) - 128_000) < 2_000)
    }

    @Test func pdfFallbackCountsPages() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = dir.appendingPathComponent("doc.pdf")
        try writePDF(pdf, pages: 4)
        #expect(MediaColumns.extract(pdf, fields: [.pages], source: .fallbackOnly).pages == 4)
    }

    @Test func plainTextYieldsNothingAndDoesNotCrash() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let txt = dir.appendingPathComponent("a.txt")
        try Data("hello".utf8).write(to: txt)
        let v = MediaColumns.extract(txt, fields: .all, source: .fallbackOnly)
        #expect(v == MediaColumns.Attributes())
    }

    @Test func spotlightFirstNeverLosesWhatFallbackKnows() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let jpg = dir.appendingPathComponent("shot.jpg")
        try writeJPEG(jpg, width: 30, height: 20)
        // A temp file is usually unindexed, so Spotlight is empty; the fallback must fill in.
        let v = MediaColumns.extract(jpg, fields: [.dimensions])
        #expect(v.width == 30 && v.height == 20)
    }

    @Test func labelsFormatCompactly() {
        #expect(MediaColumns.durationLabel(3) == "0:03")
        #expect(MediaColumns.durationLabel(75.4) == "1:15")
        #expect(MediaColumns.durationLabel(3725) == "1:02:05")
        #expect(MediaColumns.durationLabel(.infinity) == "—")
        #expect(MediaColumns.Attributes(width: Int.max, height: 2).pixelArea == nil)
        #expect(MediaColumns.bitRateLabel(320_000) == "320 kbps")
        #expect(MediaColumns.bitRateLabel(1_411_200) == "1,411 kbps")
        #expect(MediaColumns.bitRateLabel(0) == nil)
        #expect(MediaColumns.cameraLabel(make: "Canon", model: "Canon EOS R5") == "Canon EOS R5")
        #expect(MediaColumns.cameraLabel(make: "Apple", model: "iPhone 15") == "Apple iPhone 15")
        #expect(MediaColumns.cameraLabel(make: nil, model: "Pixel 8") == "Pixel 8")
        #expect(MediaColumns.cameraLabel(make: " ", model: nil) == nil)
        #expect(MediaColumns.codecName(fourCC: "aac ") == "AAC")
        #expect(MediaColumns.codecName(fourCC: "avc1") == "H.264")
        #expect(MediaColumns.codecName(fourCC: "zzzz") == "zzzz")
        let a = MediaColumns.Attributes(width: 1920, height: 1080)
        #expect(a.dimensionsLabel == "1920 × 1080")
        #expect(MediaColumns.Attributes().dimensionsLabel == nil)
    }

    @Test func cacheKeyTracksPathSizeAndModificationTime() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("f.bin")
        try Data("one".utf8).write(to: file)
        let k1 = try #require(MediaColumns.CacheKey(url: file))
        let k1again = try #require(MediaColumns.CacheKey(url: file))
        #expect(k1 == k1again)
        try Data("longer".utf8).write(to: file)
        let k2 = try #require(MediaColumns.CacheKey(url: file))
        #expect(k2 != k1)  // size changed
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: file.path)
        let k3 = try #require(MediaColumns.CacheKey(url: file))
        #expect(k3 != k2 && k3.size == k2.size)  // mtime alone changed
        #expect(MediaColumns.CacheKey(url: dir.appendingPathComponent("missing")) == nil)
    }

    @Test func cacheServesRepeatsAndWidensOnNewFields() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let jpg = dir.appendingPathComponent("shot.jpg")
        try writeJPEG(jpg, width: 10, height: 12)
        let cache = MediaColumns.Cache(capacity: 8)
        let first = cache.values(for: jpg, fields: [.dimensions], source: .fallbackOnly)
        #expect(first.width == 10)
        _ = cache.values(for: jpg, fields: [.dimensions], source: .fallbackOnly)
        #expect(cache.extractions == 1)  // second call was a hit
        let wider = cache.values(for: jpg, fields: [.dimensions, .camera], source: .fallbackOnly)
        #expect(wider.camera == "Fujifilm X100V" && wider.width == 10)
        #expect(cache.extractions == 2)  // a new field forces one more read
        // Changing the file invalidates by key.
        try writeJPEG(jpg, width: 20, height: 22)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: jpg.path)
        #expect(cache.values(for: jpg, fields: [.dimensions], source: .fallbackOnly).width == 20)
    }

    @Test func cacheIsBounded() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = MediaColumns.Cache(capacity: 4)
        for i in 0..<10 {
            let f = dir.appendingPathComponent("f\(i).txt")
            try Data("x".utf8).write(to: f)
            _ = cache.values(for: f, fields: [.pages], source: .fallbackOnly)
        }
        #expect(cache.count <= 4)
    }

    @Test func sortingByLazyMetadataOrdersAndPutsMissingLast() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        func entry(_ name: String) throws -> FileEntry {
            let f = dir.appendingPathComponent(name)
            try Data("x".utf8).write(to: f)
            return FileEntry(
                name: name, isDirectory: false, size: 1, modificationDate: nil)
        }
        var a = try entry("a")
        var b = try entry("b")
        var c = try entry("c")
        a.viewMetadata = FileViewMetadata(media: .init(duration: 90))
        b.viewMetadata = FileViewMetadata(media: .init(duration: 30))
        c.viewMetadata = FileViewMetadata(media: .init())  // no duration
        var fmt = ViewFormat(sortKey: .duration)
        #expect(fmt.sorted([a, b, c]).map(\.name) == ["c", "b", "a"])  // missing sorts first ascending
        fmt.ascending = false
        #expect(fmt.sorted([a, b, c]).map(\.name) == ["a", "b", "c"])
        #expect(fmt.metadataRequirements.contains(.media))
        #expect(ViewFormat(sortKey: .name).metadataRequirements.isEmpty)
        #expect(MediaColumns.Fields(sortKey: .camera) == .camera)
    }

    @Test func enrichmentIsCancellableAndHonorsRequirements() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var entries: [FileEntry] = []
        for i in 0..<50 {
            let f = dir.appendingPathComponent("p\(i).pdf")
            try writePDF(f, pages: 2)
            entries.append(
                FileEntry(name: "p\(i).pdf", isDirectory: false, size: 1, modificationDate: nil))
        }
        let completed = Mutex<[Int]>([])
        let done = FileViewMetadata.enrich(
            entries, directory: dir, requirements: .media, mediaFields: [.pages],
            mediaSource: .fallbackOnly,
            progress: { count, _ in
                completed.withLock { $0.append(count) }
            })
        #expect(done.allSatisfy { $0.viewMetadata?.media?.pages == 2 })
        #expect(completed.withLock { $0 } == [1, 32, 50])
        // A cancelled task stops before reading everything.
        let snapshot = entries
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return FileViewMetadata.enrich(
                snapshot, directory: dir, requirements: .media, mediaFields: [.pages],
                mediaSource: .fallbackOnly)
        }
        let partial = await task.value
        #expect(partial.filter { $0.viewMetadata?.media?.pages != nil }.count < entries.count)
    }

    @Test func columnIDsMapToFieldsAndSortKeys() {
        #expect(MediaColumns.Fields.all.contains([.dimensions, .dateTaken, .camera]))
        #expect(MediaColumns.Fields(sortKey: .name) == nil)
        #expect(MediaColumns.Fields(sortKey: .bitRate) == .bitRate)
        // An older formats.json with an unknown sort key still loads as Name.
        let old = Data(#"{"sortKey":"holographic","ascending":false}"#.utf8)
        let fmt = try? JSONDecoder().decode(ViewFormat.self, from: old)
        #expect(fmt?.sortKey == .name && fmt?.ascending == false)
        let new = Data(#"{"sortKey":"dateTaken"}"#.utf8)
        #expect((try? JSONDecoder().decode(ViewFormat.self, from: new))?.sortKey == .dateTaken)
    }
}
