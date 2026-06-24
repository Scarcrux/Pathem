import Foundation
import Testing

@testable import PathemEngine

@Suite struct FileHasherTests {
    private func tempFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pathem-hash-\(UUID().uuidString)")
        try Data(contents.utf8).write(to: url)
        return url
    }

    @Test func sha256OfKnownInput() throws {
        let url = try tempFile("abc")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(
            try FileHasher.hash(url, algorithm: .sha256)
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func md5AndSha1OfKnownInput() throws {
        let url = try tempFile("abc")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try FileHasher.hash(url, algorithm: .md5) == "900150983cd24fb0d6963f7d28e17f72")
        #expect(try FileHasher.hash(url, algorithm: .sha1) == "a9993e364706816aba3e25717850c26c9cd0d89d")
    }

    @Test func emptyFileSha256() throws {
        let url = try tempFile("")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(
            try FileHasher.hash(url)
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func chunkBoundaryMatchesSingleShot() throws {
        let url = try tempFile(String(repeating: "pathem-", count: 5000))  // ~35 KB
        defer { try? FileManager.default.removeItem(at: url) }
        // A tiny buffer forces many chunks; the digest must be identical.
        let chunked = try FileHasher.hash(url, algorithm: .sha256, bufferSize: 7)
        let oneShot = try FileHasher.hash(url, algorithm: .sha256, bufferSize: 1 << 20)
        #expect(chunked == oneShot)
    }
}
