import Foundation
import Testing

@testable import PathemEngine

@Suite("FinderPreferences mapping")
struct FinderPreferencesTests {
    @Test func boolValueNormalizesFinderRepresentations() {
        #expect(FinderPreferences.boolValue(true) == true)
        #expect(FinderPreferences.boolValue(NSNumber(value: 1)) == true)
        #expect(FinderPreferences.boolValue(NSNumber(value: 0)) == false)
        #expect(FinderPreferences.boolValue("YES") == true)
        #expect(FinderPreferences.boolValue("no") == false)
        #expect(FinderPreferences.boolValue("1") == true)
        #expect(FinderPreferences.boolValue(nil) == nil)  // absent key -> leave Pathem's setting alone
        #expect(FinderPreferences.boolValue("garbage") == nil)
    }

    @Test func viewStyleCodesMapToPathemModes() {
        #expect(FinderPreferences.viewMode(from: "icnv") == .icon)
        #expect(FinderPreferences.viewMode(from: "Nlsv") == .list)
        #expect(FinderPreferences.viewMode(from: "clmv") == .column)
        #expect(FinderPreferences.viewMode(from: "glyv") == .gallery)
        #expect(FinderPreferences.viewMode(from: nil) == nil)
        #expect(FinderPreferences.viewMode(from: "wxyz") == nil)  // unknown -> untouched
    }

    @Test func matchedCombinesTheThreeKeys() {
        let m = FinderPreferences.matched(
            showAllFiles: "YES", sortFoldersFirst: NSNumber(value: 0), viewStyle: "clmv")
        #expect(m == FinderPreferences.Matched(showHidden: true, foldersFirst: false, defaultView: .column))
    }

    @Test func absentKeysLeaveNilSoNothingIsForced() {
        let m = FinderPreferences.matched(showAllFiles: nil, sortFoldersFirst: nil, viewStyle: nil)
        #expect(m == FinderPreferences.Matched())
    }
}
