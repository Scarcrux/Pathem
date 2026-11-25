import Foundation
import Testing

@testable import PathemEngine

@Suite struct SelectionSummaryTests {
    private func file(_ name: String, _ size: Int64) -> FileEntry {
        FileEntry(name: name, isDirectory: false, size: size, modificationDate: nil)
    }
    private func folder(_ name: String) -> FileEntry {
        FileEntry(name: name, isDirectory: true, size: 0, modificationDate: nil)
    }

    @Test func totalsAndBreakdownByKind() {
        let selected = [
            file("a.png", 100), file("b.jpg", 50), file("c.mp3", 400), file("d.zip", 5),
        ]
        let summary = SelectionSummary.summarize(
            selected: selected, totalCount: 120, folderSize: { _ in nil })
        #expect(summary.selectedCount == 4)
        #expect(summary.totalCount == 120)
        #expect(summary.bytes == 555)
        #expect(summary.unmeasuredFolders == 0)
        #expect(!summary.isApproximate)
        #expect(summary.slices.map(\.kind) == [.audio, .image, .archive])
        #expect(summary.slices[1].count == 2)
        #expect(summary.slices[1].bytes == 150)
    }

    @Test func foldersCountOnlyWhenTheirSizeIsKnown() {
        let selected = [file("a.txt", 10), folder("known"), folder("unknown1"), folder("unknown2")]
        let summary = SelectionSummary.summarize(
            selected: selected, totalCount: 9,
            folderSize: { $0.name == "known" ? 1_000 : nil })
        #expect(summary.bytes == 1_010)
        #expect(summary.unmeasuredFolders == 2)
        // Folders still appear in the breakdown, by count.
        #expect(summary.slices.first { $0.kind == .folder }?.count == 3)
    }

    @Test func largeSelectionsAreSampledAndFlaggedApproximate() {
        let selected = (0..<30).map { file("f\($0).txt", 1) }
        let summary = SelectionSummary.summarize(
            selected: selected, totalCount: 30, cap: 10, folderSize: { _ in nil })
        #expect(summary.isApproximate)
        #expect(summary.selectedCount == 30)
        #expect(summary.bytes == 10)
        #expect(summary.slices.map(\.count).reduce(0, +) == 10)
    }

    @Test func emptySelectionIsEmpty() {
        let summary = SelectionSummary.summarize(
            selected: [], totalCount: 5, folderSize: { _ in nil })
        #expect(summary.slices.isEmpty)
        #expect(summary.bytes == 0)
    }
}
