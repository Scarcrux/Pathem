import Foundation
import Testing

@testable import PathemEngine

@Suite("FolderSizeCache")
struct FolderSizeCacheTests {
    @Test func hitOnlyWhenMtimeUnchanged() {
        var cache = FolderSizeCache()
        cache.record(path: "/a", measurement: .init(bytes: 100, complete: true), mtime: 1000)
        #expect(cache.measurement(forPath: "/a", currentMtime: 1000)?.bytes == 100)
        // Changed mtime (the folder's contents changed) invalidates the entry.
        #expect(cache.measurement(forPath: "/a", currentMtime: 1001) == nil)
        // Unknown path misses.
        #expect(cache.measurement(forPath: "/b", currentMtime: 1000) == nil)
    }

    @Test func recordPreservesCompleteFlag() {
        var cache = FolderSizeCache()
        cache.record(path: "/x", measurement: .init(bytes: 5, complete: false), mtime: 1)
        #expect(cache.measurement(forPath: "/x", currentMtime: 1)?.complete == false)
    }

    @Test func lruEvictsOldestOverCap() {
        var cache = FolderSizeCache(maxEntries: 2)
        cache.record(path: "/1", measurement: .init(bytes: 1, complete: true), mtime: 1)
        cache.record(path: "/2", measurement: .init(bytes: 2, complete: true), mtime: 1)
        cache.record(path: "/3", measurement: .init(bytes: 3, complete: true), mtime: 1)  // evicts /1
        #expect(cache.count == 2)
        #expect(cache.measurement(forPath: "/1", currentMtime: 1) == nil)
        #expect(cache.measurement(forPath: "/3", currentMtime: 1)?.bytes == 3)
    }

    @Test func roundTripsThroughJSON() throws {
        var cache = FolderSizeCache()
        cache.record(path: "/deep/folder", measurement: .init(bytes: 4096, complete: true), mtime: 42)
        let decoded = try JSONDecoder().decode(
            FolderSizeCache.self, from: JSONEncoder().encode(cache))
        #expect(decoded.measurement(forPath: "/deep/folder", currentMtime: 42)?.bytes == 4096)
    }

    @Test func mtimeKeyRoundsToWholeSeconds() {
        let date = Date(timeIntervalSince1970: 1000.4)
        #expect(FolderSizeCache.mtimeKey(date) == 1000)
        #expect(FolderSizeCache.mtimeKey(nil) < 0)  // distantPast
    }
}
