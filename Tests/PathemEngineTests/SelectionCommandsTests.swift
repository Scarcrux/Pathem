import Foundation
import Testing

@testable import PathemEngine

@Suite struct SelectionCommandsTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func file(_ name: String, size: Int64 = 10, at date: Date? = nil) -> FileEntry {
        FileEntry(name: name, isDirectory: false, size: size, modificationDate: date ?? t0)
    }
    private func folder(_ name: String) -> FileEntry {
        FileEntry(name: name, isDirectory: true, size: 0, modificationDate: t0)
    }

    @Test func invertFlipsTheSelection() {
        let all = [file("a"), file("b"), folder("c")]
        #expect(SelectionCommands.invert(all, selected: ["a"]) == ["b", "c"])
        #expect(SelectionCommands.invert(all, selected: []) == ["a", "b", "c"])
        #expect(SelectionCommands.invert(all, selected: ["a", "b", "c"]).isEmpty)
    }

    @Test func filesOnlyAndFoldersOnly() {
        let all = [file("a"), folder("d"), file("b")]
        #expect(SelectionCommands.allFiles(all) == ["a", "b"])
        #expect(SelectionCommands.allFolders(all) == ["d"])
    }

    @Test func sameExtensionIsCaseInsensitiveAndSkipsFolders() {
        let all = [file("a.TXT"), file("b.txt"), file("c.md"), file("noext"), folder("d.txt")]
        #expect(SelectionCommands.sameExtension(as: all[0], in: all) == ["a.TXT", "b.txt"])
        // An extensionless focus selects the other extensionless files.
        #expect(SelectionCommands.sameExtension(as: all[3], in: all) == ["noext"])
    }

    @Test func kindBucketsFollowTypeConformance() {
        #expect(FileKindBucket.of(file("p.PNG")) == .image)
        #expect(FileKindBucket.of(file("m.mov")) == .video)
        #expect(FileKindBucket.of(file("s.mp3")) == .audio)
        #expect(FileKindBucket.of(file("r.pdf")) == .document)
        #expect(FileKindBucket.of(file("x.swift")) == .code)
        #expect(FileKindBucket.of(file("z.zip")) == .archive)
        #expect(FileKindBucket.of(folder("Some.app")) == .app)
        #expect(FileKindBucket.of(folder("plain")) == .folder)
        #expect(FileKindBucket.of(file("blob.unknownext123")) == .other)
    }

    @Test func sameKindSelectsTheBucket() {
        let all = [file("a.png"), file("b.jpg"), file("c.pdf"), folder("d")]
        #expect(SelectionCommands.sameKind(as: all[0], in: all) == ["a.png", "b.jpg"])
        #expect(SelectionCommands.sameKind(as: all[3], in: all) == ["d"])
    }

    @Test func uniqueIsByNameAgainstTheOtherPane() {
        let mine = [file("a"), file("b"), file("c")]
        let other = [file("b"), file("z")]
        #expect(SelectionCommands.compare(.unique, mine, with: other) == ["a", "c"])
    }

    @Test func nameComparisonHonorsCaseAndNormalization() {
        let mine = [file("Report.txt"), file("caf\u{00E9}.txt")]
        let other = [file("report.txt"), file("cafe\u{0301}.txt")]
        #expect(SelectionCommands.compare(.unique, mine, with: other, caseSensitive: false).isEmpty)
        #expect(
            SelectionCommands.compare(.unique, mine, with: other, caseSensitive: true)
                == ["Report.txt", "caf\u{00E9}.txt"])
    }

    @Test func newerNeedsASameNameAndALaterDate() {
        let later = t0.addingTimeInterval(60)
        let mine = [file("a", at: later), file("b", at: t0), file("c", at: later), file("only")]
        let other = [file("a", at: t0), file("b", at: later), file("c", at: later)]
        #expect(SelectionCommands.compare(.newer, mine, with: other) == ["a"])
    }

    @Test func differentIsSameNameWithAnotherSizeOrDate() {
        let later = t0.addingTimeInterval(60)
        let mine = [
            file("same"), file("size", size: 5), file("date", at: later), file("only"),
        ]
        let other = [file("same"), file("size", size: 6), file("date"), file("extra")]
        #expect(SelectionCommands.compare(.different, mine, with: other) == ["size", "date"])
    }

    @Test func modificationDatesWithinASecondCountAsEqual() {
        let mine = [file("a", at: t0.addingTimeInterval(0.4))]
        let other = [file("a", at: t0)]
        #expect(SelectionCommands.compare(.different, mine, with: other).isEmpty)
        #expect(SelectionCommands.compare(.newer, mine, with: other).isEmpty)
    }
}
