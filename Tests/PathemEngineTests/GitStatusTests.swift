import Foundation
import Testing

@testable import PathemEngine

@Suite struct GitStatusTests {
    private let root = URL(fileURLWithPath: "/repo")

    @Test func parsesBranchAheadBehindAndStates() {
        let records = [
            "# branch.oid abcdef",
            "# branch.head main",
            "# branch.ab +2 -1",
            "1 .M N... 100644 100644 100644 1111 2222 src/app.swift",
            "1 A. N... 000000 100644 100644 0000 3333 added.txt",
            "? notes.md",
        ]
        let info = GitStatus.parse(porcelainZ: records.joined(separator: "\0"), repoRoot: root)
        #expect(info.branch == "main")
        #expect(info.ahead == 2)
        #expect(info.behind == 1)
        #expect(info.states["/repo/src/app.swift"] == .modified)
        #expect(info.states["/repo/added.txt"] == .added)
        #expect(info.states["/repo/notes.md"] == .untracked)
    }

    @Test func marksAncestorDirectoriesModified() {
        let info = GitStatus.parse(
            porcelainZ: "1 .M N... 100644 100644 100644 1 2 deep/nested/file.txt", repoRoot: root)
        #expect(info.states["/repo/deep"] == .modified)
        #expect(info.states["/repo/deep/nested"] == .modified)
        #expect(info.states["/repo/deep/nested/file.txt"] == .modified)
        #expect(info.states["/repo"] == nil)  // the root itself isn't badged
    }

    @Test func renameRecordConsumesItsOriginPath() {
        let records = [
            "# branch.head dev",
            "2 R. N... 100644 100644 100644 1 2 R100 new name.txt",
            "old name.txt",  // the origin path that follows a rename record
            "? after.txt",
        ]
        let info = GitStatus.parse(porcelainZ: records.joined(separator: "\0"), repoRoot: root)
        #expect(info.states["/repo/new name.txt"] == .renamed)  // path with spaces preserved
        #expect(info.states["/repo/old name.txt"] == nil)  // origin path was skipped, not parsed
        #expect(info.states["/repo/after.txt"] == .untracked)  // parsing stayed in sync
    }

    @Test func preservesConsecutiveSpacesInPath() {
        // A file name with two spaces must keep both, or the badge maps to a wrong path.
        let info = GitStatus.parse(
            porcelainZ: "1 .M N... 100644 100644 100644 1 2 my  file.txt", repoRoot: root)
        #expect(info.states["/repo/my  file.txt"] == .modified)
        #expect(info.states["/repo/my file.txt"] == nil)  // not collapsed
    }

    @Test func detachedHeadHasNoBranch() {
        let info = GitStatus.parse(porcelainZ: "# branch.head (detached)", repoRoot: root)
        #expect(info.branch == nil)
    }
}
