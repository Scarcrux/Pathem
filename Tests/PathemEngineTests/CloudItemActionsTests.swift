import Foundation
import Testing

@testable import PathemEngine

@Suite struct CloudItemActionsTests {
    private let plain = CloudItemFacts(isUbiquitous: false, isDataless: false, isOffloadable: false)
    private let cloudOnly = CloudItemFacts(
        isUbiquitous: true, isDataless: true, isOffloadable: false)
    private let downloaded = CloudItemFacts(
        isUbiquitous: true, isDataless: false, isOffloadable: true)
    private let downloadedPinned = CloudItemFacts(
        isUbiquitous: true, isDataless: false, isOffloadable: false)

    @Test func plainLocalFileOffersNeither() {
        let actions = CloudItemActions(for: [plain])
        #expect(!actions.showsDownloadNow)
        #expect(!actions.showsRemoveDownload)
    }

    @Test func datalessICloudItemOffersOnlyDownloadNow() {
        let actions = CloudItemActions(for: [cloudOnly])
        #expect(actions.showsDownloadNow)
        #expect(!actions.showsRemoveDownload)
    }

    @Test func downloadedICloudItemOffersOnlyRemoveDownload() {
        let actions = CloudItemActions(for: [downloaded])
        #expect(!actions.showsDownloadNow)
        #expect(actions.showsRemoveDownload)
    }

    @Test func downloadedItemThatCannotBeOffloadedOffersNeither() {
        let actions = CloudItemActions(for: [downloadedPinned])
        #expect(!actions.showsDownloadNow)
        #expect(!actions.showsRemoveDownload)
    }

    @Test func mixedSelectionOffersBothWhenEachKindIsPresent() {
        let actions = CloudItemActions(for: [plain, cloudOnly, downloaded])
        #expect(actions.showsDownloadNow)
        #expect(actions.showsRemoveDownload)
    }

    @Test func plainFilesDoNotLeakIntoAMixedSelection() {
        let actions = CloudItemActions(for: [plain, cloudOnly])
        #expect(actions.showsDownloadNow)
        #expect(!actions.showsRemoveDownload)
    }

    @Test func emptySelectionOffersNeither() {
        let actions = CloudItemActions(for: [])
        #expect(!actions.showsDownloadNow)
        #expect(!actions.showsRemoveDownload)
    }

    @Test func aDatalessItemThatIsNotUbiquitousIsNotADownload() {
        // A dataless placeholder from a non-iCloud provider is not an iCloud item.
        let other = CloudItemFacts(isUbiquitous: false, isDataless: true, isOffloadable: false)
        #expect(!CloudItemActions(for: [other]).showsDownloadNow)
    }

    @Test func factsFromAPlainFileAreNotCloud() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pathem-cloud-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let facts = CloudItemFacts(url: file)
        #expect(!facts.isUbiquitous && !facts.isDataless && !facts.isOffloadable)
        #expect(CloudItemActions(for: [facts]) == CloudItemActions(for: []))
    }
}
