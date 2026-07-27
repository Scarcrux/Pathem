import Foundation
import Testing

@testable import PathemEngine

@Suite struct ImageClassifierTests {
    @Test func tagNameTitleCasesAndSplitsUnderscores() {
        #expect(ImageClassifier.tagName(from: "beach") == "Beach")
        #expect(ImageClassifier.tagName(from: "hot_dog") == "Hot Dog")
        #expect(ImageClassifier.tagName(from: "sports_equipment") == "Sports Equipment")
        #expect(ImageClassifier.tagName(from: "") == "")
    }

    @Test func nonImageClassifiesToEmptyRatherThanCrashing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-classify-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let notImage = dir.appendingPathComponent("notimage.txt")
        try Data("not an image".utf8).write(to: notImage)
        #expect(ImageClassifier.classify(url: notImage).isEmpty)
    }
}
