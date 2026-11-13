import Foundation
import Testing

@testable import PathemEngine

@Suite struct FolderSizeSkipTests {
    private let home = "/Users/someone"
    private func reason(_ path: String, rules: [String] = []) -> FolderSizeSkip.Reason? {
        FolderSizeSkip.reason(for: path, home: home, userRules: rules)
    }

    @Test func cachesTempAndBuildOutputAreSkipped() {
        #expect(reason("/Users/someone/Library/Caches") == .cache)
        #expect(reason("/Users/someone/Library/Caches/go-build") == .cache)
        #expect(reason("/Users/someone/.cache/huggingface") == .cache)
        #expect(reason("/Users/someone/Library/Developer/Xcode/DerivedData") == .cache)
        #expect(reason("/Users/someone/.npm/_cacache") == .cache)
        #expect(reason("/Volumes/Work/project/.cache") == .cache)
        #expect(reason("/private/tmp") == .temporary)
        #expect(reason("/private/var/folders/v1/abc/T") == .temporary)
        #expect(reason("/Users/someone/Code/app/node_modules") == .regenerable)
        #expect(reason("/Users/someone/Code/app/.build") == .regenerable)
    }

    /// The control: ordinary folders, look-alike names and "review" places are still sized.
    @Test func ordinaryFoldersAreNotSkipped() {
        #expect(reason("/Users/someone/Documents") == nil)
        #expect(reason("/Users/someone/Library") == nil)
        #expect(reason("/Users/someone/Downloads") == nil)
        #expect(reason("/Users/someone/Code/app/Sources") == nil)
        #expect(reason("/Users/someone/Library/CachesOld") == nil)
        #expect(reason("/tmpfiles") == nil)
        // A parent of a skipped place is sized in full; only the place itself is skipped.
        #expect(reason("/Users/someone/.npm") == nil)
    }

    @Test func userRulesCoverPathsAndNames() {
        let rules = FolderSizeSkip.rules(from: " ~/Movies/Raw , archive\n/Volumes/Backup/")
        #expect(rules == ["~/Movies/Raw", "archive", "/Volumes/Backup/"])
        #expect(reason("/Users/someone/Movies/Raw", rules: rules) == .excluded)
        #expect(reason("/Users/someone/Movies/Raw/day1", rules: rules) == .excluded)
        #expect(reason("/Users/someone/Movies", rules: rules) == nil)
        #expect(reason("/Users/someone/Work/archive", rules: rules) == .excluded)
        #expect(reason("/Users/someone/Work/archives", rules: rules) == nil)
        #expect(reason("/Volumes/Backup", rules: rules) == .excluded)
        #expect(reason("/Volumes/Backup/2024", rules: rules) == .excluded)
    }
}
