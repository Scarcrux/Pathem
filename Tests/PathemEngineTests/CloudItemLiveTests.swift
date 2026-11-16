import Foundation
import Testing

@testable import PathemEngine

/// The real round trip behind "Remove Download" and "Download Now": a file this test creates in
/// iCloud Drive is uploaded, evicted and downloaded again, and `CloudItemFacts` must name each
/// state. Opt-in (`PATHEM_ICLOUD_LIVE_TEST=1`) because it needs a signed-in iCloud Drive and the
/// network, and takes as long as the upload does. It touches only its own folder.
@Suite struct CloudItemLiveTests {
    private static let enabled =
        ProcessInfo.processInfo.environment["PATHEM_ICLOUD_LIVE_TEST"] == "1"

    private func wait(_ seconds: Double, _ what: String, until done: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if done() { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        print("LIVE timeout waiting for \(what)")
        return done()
    }

    @Test(.enabled(if: CloudItemLiveTests.enabled))
    func evictThenDownloadRoundTrip() throws {
        let drive = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        try #require(FileManager.default.fileExists(atPath: drive.path), "iCloud Drive not present")
        let folder = drive.appendingPathComponent("pathem-live-test-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("sample.bin")
        let bytes = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try bytes.write(to: file)

        func uploaded() -> Bool {
            var url = file
            url.removeAllCachedResourceValues()
            return (try? url.resourceValues(forKeys: [.ubiquitousItemIsUploadedKey]))?
                .ubiquitousItemIsUploaded == true
        }
        func facts() -> CloudItemFacts {
            var url = file
            url.removeAllCachedResourceValues()
            return CloudItemFacts(url: url)
        }
        func actions() -> CloudItemActions { CloudItemActions(for: [facts()]) }

        try #require(wait(120, "upload") { uploaded() }, "the file never uploaded")
        print("LIVE uploaded: \(facts())")
        #expect(facts().isUbiquitous)
        #expect(!facts().isDataless)
        #expect(actions().showsRemoveDownload)
        #expect(!actions().showsDownloadNow)

        // Remove Download, through the same call the command makes.
        let result = Backup.offload([file])
        if let failure = result.failures.first {
            // iCloud Drive refuses eviction when "Optimize Mac Storage" is off. That is this
            // Mac's setting, not a defect, but the reason shown must say so.
            print("LIVE evict refused: \(failure.reason)")
            #expect(failure.reason == Backup.nonEvictableReason)
            return
        }
        #expect(wait(60, "eviction") { facts().isDataless })
        print("LIVE evicted: \(facts())")
        #expect(actions().showsDownloadNow)
        #expect(!actions().showsRemoveDownload)

        // Download Now, the same call downloadSelection makes.
        try FileManager.default.startDownloadingUbiquitousItem(at: file)
        #expect(wait(120, "download") { !facts().isDataless && facts().isOffloadable })
        print("LIVE downloaded: \(facts())")
        #expect(actions().showsRemoveDownload)
        #expect(!actions().showsDownloadNow)
        #expect(try Data(contentsOf: file) == bytes)
    }
}
