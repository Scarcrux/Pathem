import Foundation
import Testing

@testable import PathemEngine

/// An unknown enum raw value (a newer schema, or a typo) must fall back to the
/// default rather than failing the whole file and wiping the user's settings.
@Suite struct ToleranceTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test func preferencesUnknownDensityFallsBack() throws {
        let p = try decode(Preferences.self, #"{"density":"spacious","fontSize":20}"#)
        #expect(p.density == .comfortable)  // unknown -> default
        #expect(p.fontSize == 20)  // the rest of the file is preserved
    }

    @Test func viewFormatUnknownEnumsFallBack() throws {
        let v = try decode(ViewFormat.self, #"{"viewMode":"tree","sortKey":"color","ascending":false}"#)
        #expect(v.viewMode == .list)
        #expect(v.sortKey == .name)
        #expect(v.ascending == false)  // preserved
    }

    @Test func remoteConnectionBadProtoDoesNotKillTheArray() throws {
        let list = try decode(
            [RemoteConnection].self,
            #"[{"name":"a","host":"h1","proto":"scp"},{"name":"b","host":"h2","proto":"sftp"}]"#)
        #expect(list.count == 2)  // one bad element must not drop the whole array
        #expect(list[0].proto == .ftp)  // unknown -> default
        #expect(list[1].proto == .sftp)
    }

    @Test func sidebarPartialJSONFillsDefaults() throws {
        let s = try decode(Sidebar.self, #"{"groups":[{"title":"Favorites","items":[{"name":"Home"}]}]}"#)
        #expect(s.groups.count == 1)
        let item = try #require(s.groups.first?.items.first)
        #expect(item.name == "Home")
        #expect(item.icon == "folder")  // defaulted
        #expect(item.path == "")  // defaulted
    }

    @Test func sidebarEmptyJSONDecodes() throws {
        #expect(try decode(Sidebar.self, "{}").groups.isEmpty)
    }

    @Test func folderFormatsEmptyJSONIsAllDefault() throws {
        let f = try decode(FolderFormats.self, "{}")
        #expect(f.rules.isEmpty)
        #expect(f.format(for: "/anywhere") == .default)
    }

    @Test func folderFormatsRuleWithPartialFormatCascadesDefaults() throws {
        let f = try decode(
            FolderFormats.self,
            #"{"rules":[{"path":"/x","scope":"exact","format":{"viewMode":"icon"}}]}"#)
        #expect(f.format(for: "/x").viewMode == .icon)
        #expect(f.format(for: "/x").sortKey == .name)  // omitted -> default
    }

    @Test func folderFormatsBadScopeDoesNotWipeRules() throws {
        let f = try decode(
            FolderFormats.self,
            #"{"rules":[{"path":"/x","scope":"galaxy","format":{}}],"defaultFormat":{"viewMode":"icon"}}"#)
        #expect(f.rules.count == 1)  // the rule survives
        #expect(f.rules[0].scope == .exact)  // unknown scope -> default
        #expect(f.defaultFormat.viewMode == .icon)
    }
}
