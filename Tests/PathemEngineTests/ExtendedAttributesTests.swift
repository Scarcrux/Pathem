import Foundation
import Testing

@testable import PathemEngine

@Suite struct ExtendedAttributesTests {
    private func tempFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-xattr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("item.txt")
        try Data("hi".utf8).write(to: file)
        return file
    }

    private func setxattr(_ name: String, _ value: String, on url: URL) {
        let data = Data(value.utf8)
        _ = data.withUnsafeBytes { PathemEngine_setxattr(url.path, name, $0.baseAddress, data.count) }
    }

    @Test func listsNamesSizesAndTextPreview() throws {
        let file = try tempFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        setxattr("com.pathem.note", "hello world", on: file)

        let names = ExtendedAttributes.names(of: file)
        #expect(names.contains("com.pathem.note"))
        let attr = try #require(ExtendedAttributes.list(file).first { $0.name == "com.pathem.note" })
        #expect(attr.size == 11)
        #expect(attr.preview == "hello world")
    }

    @Test func removesAnAttribute() throws {
        let file = try tempFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        setxattr("com.pathem.temp", "x", on: file)
        #expect(ExtendedAttributes.names(of: file).contains("com.pathem.temp"))
        try ExtendedAttributes.remove("com.pathem.temp", from: file)
        #expect(!ExtendedAttributes.names(of: file).contains("com.pathem.temp"))
    }

    @Test func detectsAndRemovesQuarantine() throws {
        let file = try tempFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        setxattr(ExtendedAttributes.quarantineName, "0083;00000000;Safari;", on: file)
        #expect(ExtendedAttributes.isQuarantined(file))
        let removed = ExtendedAttributes.removeQuarantine(from: file)
        #expect(removed == 1)
        #expect(!ExtendedAttributes.isQuarantined(file))
    }

    @Test func removeQuarantineRecursesIntoFolders() throws {
        let file = try tempFile()
        let dir = file.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }
        let inner = dir.appendingPathComponent("inner.txt")
        try Data("x".utf8).write(to: inner)
        setxattr(ExtendedAttributes.quarantineName, "q", on: dir)
        setxattr(ExtendedAttributes.quarantineName, "q", on: file)
        setxattr(ExtendedAttributes.quarantineName, "q", on: inner)
        let removed = ExtendedAttributes.removeQuarantine(from: dir)
        #expect(removed == 3)  // the folder and both files
    }
}

/// Thin wrapper so the test can set an xattr without importing the C symbol shadowed by
/// the engine's own use.
private func PathemEngine_setxattr(
    _ path: String, _ name: String, _ value: UnsafeRawPointer?, _ size: Int
) -> Int32 {
    setxattr(path, name, value, size, 0, 0)
}
