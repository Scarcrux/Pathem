import Testing

@testable import PathemEngine

@Suite struct FuzzyMatchTests {
    @Test func matchesSubsequenceCaseInsensitively() {
        #expect(FuzzyMatch.score("cp", "Copy") != nil)  // c..p in order
        #expect(FuzzyMatch.score("COPY", "copy") != nil)
        #expect(FuzzyMatch.score("xyz", "Copy") == nil)  // no subsequence
        #expect(FuzzyMatch.score("yc", "Copy") == nil)  // wrong order
    }

    @Test func emptyQueryMatchesEverything() {
        #expect(FuzzyMatch.score("", "anything") == 0)
        #expect(FuzzyMatch.rank(["a", "b"], query: "", key: { $0 }) == ["a", "b"])
    }

    @Test func prefixBeatsMidWord() {
        let prefix = FuzzyMatch.score("co", "Copy")!
        let mid = FuzzyMatch.score("co", "Recolor")!
        #expect(prefix > mid)
    }

    @Test func wordStartBeatsBuried() {
        // "op" against the start of the word "Other Pane" should beat "op" buried in "Compose".
        let wordStart = FuzzyMatch.score("op", "Copy to Other Pane")!
        let buried = FuzzyMatch.score("op", "Compose")!
        #expect(wordStart > buried)
    }

    @Test func rankFiltersAndOrders() {
        let items = ["Copy", "Copy to Other Pane", "Recompose", "Cut"]
        let ranked = FuzzyMatch.rank(items, query: "cop", key: { $0 })
        #expect(ranked.first == "Copy")  // tight prefix match wins
        #expect(!ranked.contains("Cut"))  // "cop" is not a subsequence of "Cut"
    }

    @Test func rankIsStableForTies() {
        let items = ["ab x", "ab y", "ab z"]
        let ranked = FuzzyMatch.rank(items, query: "ab", key: { $0 })
        #expect(ranked == items)  // identical scores keep original order
    }
}

@Suite struct FuzzyMatchKeywordTests {
    private struct Item {
        let title: String
        let keywords: [String]
    }

    private let settings = Item(title: "Settings…", keywords: ["Preferences", "Prefs"])
    private let copy = Item(title: "Copy", keywords: [])

    @Test func keywordsFindACommandWhoseTitleDoesNotMatch() {
        let items = [copy, settings]
        for query in ["pref", "Preferences", "prefs"] {
            let ranked = FuzzyMatch.rank(
                items, query: query, key: { $0.title }, keywords: { $0.keywords })
            #expect(ranked.map(\.title) == ["Settings…"], "query \(query)")
        }
        // Without keywords the old title-only behavior finds nothing.
        #expect(FuzzyMatch.rank(items, query: "pref", key: { $0.title }).isEmpty)
    }

    @Test func aTitleMatchBeatsAKeywordMatchOfTheSameText() {
        let prefsViewer = Item(title: "Preferences Viewer", keywords: [])
        let ranked = FuzzyMatch.rank(
            [settings, prefsViewer], query: "preferences", key: { $0.title },
            keywords: { $0.keywords })
        #expect(ranked.map(\.title) == ["Preferences Viewer", "Settings…"])
    }

    @Test func aKeywordNeverReplacesTheTitleAndEmptyQueryKeepsOrder() {
        let ranked = FuzzyMatch.rank(
            [settings], query: "prefs", key: { $0.title }, keywords: { $0.keywords })
        #expect(ranked.first?.title == "Settings…")
        let all = FuzzyMatch.rank(
            [copy, settings], query: "", key: { $0.title }, keywords: { $0.keywords })
        #expect(all.map(\.title) == ["Copy", "Settings…"])
    }
}
