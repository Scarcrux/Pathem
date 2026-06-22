import AppKit
import CoreGraphics
import CoreText
import Foundation
import Testing

@testable import PathemEngine

@Suite struct ContentExtractorTests {
    private func withTempDir(_ body: (URL) throws -> Void) throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pathem-extract-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try body(dir)
    }

    @Test func readsTextLikeFiles() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("notes.md")
            try "hello semantic world".write(to: url, atomically: true, encoding: .utf8)
            let snippet = ContentExtractor.snippet(of: url)
            #expect(snippet?.contains("semantic") == true)
        }
    }

    @Test func skipsNonTextExtensions() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("image.jpg")
            try Data([0xFF, 0xD8, 0xFF, 0xE0]).write(to: url)  // JPEG header bytes
            #expect(ContentExtractor.snippet(of: url) == nil)
        }
    }

    @Test func respectsByteCap() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("big.txt")
            try String(repeating: "a", count: 20_000).write(to: url, atomically: true, encoding: .utf8)
            let snippet = ContentExtractor.snippet(of: url, maxBytes: 8192)
            #expect(snippet != nil)
            #expect((snippet?.utf8.count ?? .max) <= 8192)
        }
    }

    @Test func returnsNilForMissingFile() {
        let url = URL(fileURLWithPath: "/no/such/pathem/file-\(UUID().uuidString).txt")
        #expect(ContentExtractor.snippet(of: url) == nil)
    }

    @Test func readsPDFText() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("doc.pdf")
            try Self.makePDF(text: "semanticpdfcontent", at: url)
            let snippet = ContentExtractor.snippet(of: url)
            #expect(snippet?.contains("semanticpdfcontent") == true)
        }
    }

    /// Generate a one-page PDF with selectable (extractable) text via CoreText.
    private static func makePDF(text: String, at url: URL) throws {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var box = CGRect(x: 0, y: 0, width: 300, height: 300)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        ctx.beginPDFPage(nil)
        let attributed = NSAttributedString(
            string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)])
        let line = CTLineCreateWithAttributedString(attributed)
        ctx.textPosition = CGPoint(x: 20, y: 150)
        CTLineDraw(line, ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        try (data as Data).write(to: url)
    }
}
