import Foundation
import Testing

@testable import PathemEngine

struct FolderViewOptionsTests {
    @Test func olderFormatsKeepRelativeDefaults() throws {
        let old = try JSONDecoder().decode(
            ViewFormat.self, from: Data(#"{"viewMode":"icon"}"#.utf8))
        #expect(old.viewMode == .icon)
        #expect(old.options.dateDisplay == nil)
        #expect(old.options.inheriting(.defaults(.default)).dateDisplay == .relative)
    }

    @Test func overridesRoundTripAndStayScoped() throws {
        var options = FolderViewOptions()
        options.dateDisplay = .medium
        options.fontSize = 17
        options.iconScale = 1.5
        options.listIconSize = 32
        options.showIconPreviews = false
        options.gridSpacing = 20
        options.labelPosition = .right
        options.columns = ["name", "tags", "dateAdded", "sharedBy", "modifiedBy", "version"]
        options.columnWidths = ["name": 360]
        options.showLibraryFolder = true
        let format = ViewFormat(options: options)
        var folders = FolderFormats()
        folders.setSubtree("/fixture", format)
        folders.setExact("/fixture/exact", ViewFormat())
        let restored = try JSONDecoder().decode(
            FolderFormats.self, from: JSONEncoder().encode(folders))
        #expect(restored.format(for: "/fixture/child").options == options)
        #expect(restored.format(for: "/fixture/exact").options.dateDisplay == nil)
        #expect(restored.format(for: "/fixture-other").options.dateDisplay == nil)
        #expect(options.inheriting(.defaults(.default)).dateDisplay == .medium)
    }

    @Test func hostileConfigIsBoundedWithoutLosingColumnOrder() {
        var options = FolderViewOptions()
        options.fontSize = 400
        options.iconScale = .infinity
        options.gridSpacing = -10
        options.listIconSize = 1000
        options.columns = ["tags", "tags", "unknown", "name"]
        options.columnWidths = ["name": .nan, "tags": -12, "unknown": 10]
        let normalized = options.normalized
        #expect(normalized.fontSize == 24 && normalized.iconScale == 1)
        #expect(normalized.gridSpacing == 0 && normalized.listIconSize == 64)
        #expect(normalized.columns == ["tags", "name"])
        #expect(normalized.columnWidths == ["name": 150, "tags": 40])
        options.columns = []
        #expect(options.normalized.columns == ["name"])
    }

    @Test func unsharedPlainFileDoesNotInventPeopleOrVersion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("plain.txt")
        try Data("sample".utf8).write(to: file)
        let info = FileColumns.gather(file, .finder)
        #expect(info.sharedBy == nil && info.modifiedBy == nil && info.version == nil)
        #expect(info.cloudStatus == nil)
    }
}
