import Foundation
import Testing

@testable import PathemEngine

@Suite struct OperationLogTests {
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pathem-oplog-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func recordRoundTripsAsOneLine() throws {
        let r = OperationRecord(
            time: Date(timeIntervalSince1970: 1_700_000_000.125),
            operation: "move", sources: ["/a/x\ny.txt", "/a/\"q\".txt"], destination: "/b",
            bytes: 42, outcome: .partial, error: "one failed", undoToken: "tok")
        let line = try OperationLog.encodeLine(r)
        #expect(line.filter { $0 == 0x0A }.count == 1)  // embedded newline stays escaped
        let back = OperationLog.decodeLines(line)
        #expect(back == [r])
    }

    @Test func minimalLineDecodesWithDefaults() {
        let data = Data(#"{"operation":"trash"}"#.utf8)
        let r = OperationLog.decodeLines(data).first
        #expect(r?.operation == "trash")
        #expect(r?.sources == [] && r?.itemCount == 0 && r?.outcome == .ok)
        #expect(r?.admin == false && r?.undoToken == nil && r?.bytes == nil)
        let odd = Data(
            #"{"operation":"copy","outcome":"exploded","sources":["/a"],"future":1}"#.utf8)
        let o = OperationLog.decodeLines(odd).first
        #expect(o?.outcome == .ok && o?.itemCount == 1)  // unknown outcome and unknown keys tolerated
        #expect(
            OperationLog.decodeLines(Data("not json\n{\"operation\":\"a\"}\n{\"torn".utf8)).count
                == 1)
    }

    @Test func appendAndReadNewestFirstPrivately() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = OperationLog(directory: dir)
        for i in 0..<3 { #expect(log.append(OperationRecord(operation: "op\(i)"))) }
        #expect(log.entries().map(\.operation) == ["op2", "op1", "op0"])
        let perms =
            try FileManager.default.attributesOfItem(atPath: log.fileURL.path)[.posixPermissions]
            as? Int
        #expect(perms == 0o600)
        // A fresh instance on the same directory sees the same history.
        #expect(OperationLog(directory: dir).entries().count == 3)
    }

    @Test func rotatesAtEntryLimitKeepingOneBackup() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = OperationLog(directory: dir, maxEntries: 5)
        for i in 0..<12 { log.append(OperationRecord(operation: "op\(i)")) }
        #expect(FileManager.default.fileExists(atPath: log.rotatedURL.path))
        let current = OperationLog.decodeLines((try? Data(contentsOf: log.fileURL)) ?? Data())
        #expect(current.count <= 5)
        let all = log.entries()
        #expect(all.first?.operation == "op11")
        #expect(all.count <= 10 && all.count >= 7)  // bounded: at most two files of 5
    }

    @Test func rotatesAtByteLimit() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = OperationLog(directory: dir, maxEntries: 10_000, maxBytes: 600)
        for i in 0..<20 {
            log.append(OperationRecord(operation: "op\(i)", sources: ["/path/to/file-\(i).txt"]))
        }
        let size =
            (try? FileManager.default.attributesOfItem(atPath: log.fileURL.path)[.size] as? Int)
            ?? 0
        #expect(size <= 600)
        #expect(FileManager.default.fileExists(atPath: log.rotatedURL.path))
    }

    @Test func oversizedRecordDoesNotDisplaceRecentActivity() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = OperationLog(directory: dir, maxBytes: 600)
        #expect(log.append(OperationRecord(operation: "copy")))
        #expect(
            !log.append(
                OperationRecord(operation: "move", sources: [String(repeating: "x", count: 600)])))
        #expect(log.entries().map(\.operation) == ["copy"])
        #expect(log.entries(limit: -1).isEmpty)
    }

    @Test func defaultLimitsMatchTheDesign() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = OperationLog(directory: dir)
        #expect(log.maxEntries == 10_000 && log.maxBytes == 5_000_000)
    }

    @Test func clearRemovesBothFilesAndLogStartsAgain() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = OperationLog(directory: dir, maxEntries: 2)
        for i in 0..<5 { log.append(OperationRecord(operation: "op\(i)")) }
        log.clear()
        #expect(log.entries().isEmpty)
        log.append(OperationRecord(operation: "after"))
        #expect(log.entries().map(\.operation) == ["after"])
    }

    @Test func queuedWriteCannotRecreateRemovedConfigDirectory() throws {
        let dir = tempDir()
        let log = OperationLog(directory: dir)
        #expect(log.append(OperationRecord(operation: "copy")))
        try FileManager.default.removeItem(at: dir)
        #expect(!log.append(OperationRecord(operation: "move")))
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func searchMatchesOperationPathAndErrorTerms() {
        let r = OperationRecord(
            operation: "copy", sources: ["/Users/x/Photos/IMG_1.jpg"], destination: "/Backup",
            outcome: .failed, error: "Disk full")
        #expect(r.matches(""))
        #expect(r.matches("img_1 backup"))
        #expect(r.matches("DISK"))
        #expect(r.matches("copy failed"))
        #expect(!r.matches("trash"))
        #expect(!r.matches("img_1 nothere"))
    }
}
