import Foundation
import Testing

@testable import PathemEngine

@Suite struct FolderSizeSkipTests {
    private let home = "/Users/example"
    private func reason(_ path: String, rules: [String] = []) -> FolderSizeSkip.Reason? {
        FolderSizeSkip.reason(for: path, home: home, userRules: rules)
    }

    @Test func cachesTempAndBuildOutputAreSkipped() {
        #expect(reason("/Users/example/Library/Caches") == .cache)
        #expect(reason("/Users/example/Library/Caches/go-build") == .cache)
        #expect(reason("/Users/example/.cache/huggingface") == .cache)
        #expect(reason("/Users/example/Library/Developer/Xcode/DerivedData") == .cache)
        #expect(reason("/Users/example/.npm/_cacache") == .cache)
        #expect(reason("/Volumes/Work/project/.cache") == .cache)
        #expect(reason("/private/tmp") == .temporary)
        #expect(reason("/private/var/folders/v1/abc/T") == .temporary)
        #expect(reason("/Users/example/Code/app/node_modules") == .regenerable)
        #expect(reason("/Users/example/Code/app/.build") == .regenerable)
    }

    /// The control: ordinary folders, look-alike names and "review" places are still sized.
    @Test func ordinaryFoldersAreNotSkipped() {
        #expect(reason("/Users/example/Documents") == nil)
        #expect(reason("/Users/example/Library") == nil)
        #expect(reason("/Users/example/Downloads") == nil)
        #expect(reason("/Users/example/Code/app/Sources") == nil)
        #expect(reason("/Users/example/Library/CachesOld") == nil)
        #expect(reason("/tmpfiles") == nil)
        // A parent of a skipped place is sized in full; only the place itself is skipped.
        #expect(reason("/Users/example/.npm") == nil)
    }

    @Test func userRulesCoverPathsAndNames() {
        let rules = FolderSizeSkip.rules(from: " ~/Movies/Raw , archive\n/Volumes/Backup/")
        #expect(rules == ["~/Movies/Raw", "archive", "/Volumes/Backup/"])
        #expect(reason("/Users/example/Movies/Raw", rules: rules) == .excluded)
        #expect(reason("/Users/example/Movies/Raw/day1", rules: rules) == .excluded)
        #expect(reason("/Users/example/Movies", rules: rules) == nil)
        #expect(reason("/Users/example/Work/archive", rules: rules) == .excluded)
        #expect(reason("/Users/example/Work/archives", rules: rules) == nil)
        #expect(reason("/Volumes/Backup", rules: rules) == .excluded)
        #expect(reason("/Volumes/Backup/2024", rules: rules) == .excluded)
    }
}
