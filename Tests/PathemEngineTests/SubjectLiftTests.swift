import Foundation
import Testing

@testable import PathemEngine

@Suite struct SubjectLiftTests {
    @Test func cutoutNameAppendsCutoutPng() {
        #expect(SubjectLift.cutoutName(for: "photo.jpg") == "photo Cutout.png")
        #expect(SubjectLift.cutoutName(for: "IMG_1234.HEIC") == "IMG_1234 Cutout.png")
        #expect(SubjectLift.cutoutName(for: "no-extension") == "no-extension Cutout.png")
    }

    @Test func nonImageThrowsNoSubjectRatherThanCrashing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-lift-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let notImage = dir.appendingPathComponent("notimage.txt")
        try Data("hello, not an image".utf8).write(to: notImage)
        let out = dir.appendingPathComponent("out.png")
        #expect(throws: SubjectLift.NoSubjectFound.self) {
            try SubjectLift.removeBackground(from: notImage, to: out)
        }
        #expect(!FileManager.default.fileExists(atPath: out.path))  // nothing written on failure
    }
}
