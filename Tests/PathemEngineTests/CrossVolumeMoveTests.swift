import Foundation
import Testing

@testable import PathemEngine

@Suite(.serialized) struct CrossVolumeMoveTests {
    private let payload = Data("fixture bytes".utf8)

    @Test func copiesThenDeletesSourceAcrossVolumes() throws {
        try withVolume { scratch, volume in
            let source = scratch.appendingPathComponent("data.bin")
            try payload.write(to: source)
            let landed = volume.appendingPathComponent(source.lastPathComponent)
            #expect(!FileOperations.sameVolume(source, landed))
            let outcome = FileOperations.move(urls: [source], into: volume)
            #expect(outcome.failures.isEmpty)
            #expect(outcome.performed.count == 1)
            #expect(try Data(contentsOf: landed) == payload)
            #expect(!FileManager.default.fileExists(atPath: source.path))

            let undo = FileOperations.undo(outcome.performed)
            #expect(undo.failures.isEmpty)
            #expect(try Data(contentsOf: source) == payload)
            #expect(!FileManager.default.fileExists(atPath: landed.path))
        }
    }

    enum Protection: CaseIterable { case immutable, readOnlyFolder, denyDeleteACL }

    @Test(arguments: Protection.allCases) func keepsCompleteCopyWhenSourceRemovalFails(
        _ protection: Protection
    ) throws {
        try withVolume { scratch, volume in
            let tree = scratch.appendingPathComponent("tree")
            let nested = tree.appendingPathComponent("nested")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let names = (0..<10).map { "sibling-\($0)" } + ["nested/protected"]
            for name in names { try payload.write(to: tree.appendingPathComponent(name)) }
            let protected = nested.appendingPathComponent("protected")
            defer {
                _ = chflags(protected.path, 0)
                _ = chmod(nested.path, 0o700)
                _ = Self.run("/bin/chmod", ["-N", protected.path])
                let landed = volume.appendingPathComponent("tree/nested/protected")
                _ = chflags(landed.path, 0)
                _ = chmod(landed.deletingLastPathComponent().path, 0o700)
                _ = Self.run("/bin/chmod", ["-N", landed.path])
            }
            switch protection {
            case .immutable: try #require(chflags(protected.path, UInt32(UF_IMMUTABLE)) == 0)
            case .readOnlyFolder: try #require(chmod(nested.path, 0o555) == 0)
            case .denyDeleteACL:
                try #require(
                    Self.run("/bin/chmod", ["+a", "everyone deny delete", protected.path]))
            }

            let outcome = FileOperations.move(urls: [tree], into: volume)
            #expect(outcome.failures.count == 1)
            #expect(outcome.performed.isEmpty)
            #expect(try Data(contentsOf: protected) == payload)
            let landed = volume.appendingPathComponent("tree")
            let incompleteMove = try #require(outcome.failures.first?.incompleteMove)
            let remainingPaths = incompleteMove.remainingSourceItems.map {
                $0.resolvingSymlinksInPath().path
            }
            #expect(remainingPaths.contains(protected.resolvingSymlinksInPath().path))
            for name in names {
                #expect((try? Data(contentsOf: landed.appendingPathComponent(name))) == payload)
            }
            #expect(outcome.failures.first?.reason.contains(landed.path) == true)
        }
    }

    @Test(arguments: [false, true]) func readOnlyDestinationFails(_ acrossVolumes: Bool) throws {
        let check: (URL, URL) throws -> Void = { scratch, volume in
            let source = scratch.appendingPathComponent("source")
            try self.payload.write(to: source)
            let destination = volume.appendingPathComponent("destination")
            try FileManager.default.createDirectory(
                at: destination, withIntermediateDirectories: false)
            try #require(chmod(destination.path, 0o500) == 0)
            defer { _ = chmod(destination.path, 0o700) }
            #expect(throws: (any Error).self) {
                try ProgressiveCopy.copy(
                    from: source, to: destination.appendingPathComponent("copy"), onBytes: { _ in })
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
            #expect(try Data(contentsOf: source) == self.payload)
        }
        if acrossVolumes {
            try withVolume(check)
        } else {
            try withScratch { try check($0, $0) }
        }
    }

    @Test(arguments: [false, true]) func unreadableSourceSurvives(_ directory: Bool) throws {
        try withVolume { scratch, volume in
            let source = scratch.appendingPathComponent("source")
            let file = directory ? source.appendingPathComponent("unreadable") : source
            if directory {
                try FileManager.default.createDirectory(
                    at: source, withIntermediateDirectories: false)
                try payload.write(to: source.appendingPathComponent("readable"))
            }
            try payload.write(to: file)
            try #require(chmod(file.path, 0) == 0)
            defer { _ = chmod(file.path, 0o600) }
            let before = try FileManager.default.contentsOfDirectory(atPath: volume.path)
            let outcome = FileOperations.move(urls: [source], into: volume)
            #expect(outcome.failures.count == 1)
            #expect(outcome.performed.isEmpty)
            #expect(chmod(file.path, 0o600) == 0)
            #expect((try? Data(contentsOf: file)) == payload)
            let after = try FileManager.default.contentsOfDirectory(atPath: volume.path)
            #expect(Set(before) == Set(after))
        }
    }

    @Test(arguments: [false, true]) func unreadableReplaceKeepsOriginal(_ move: Bool) throws {
        try withVolume { scratch, volume in
            let source = scratch.appendingPathComponent("conflict")
            let original = volume.appendingPathComponent("conflict")
            try Data("replacement".utf8).write(to: source)
            try payload.write(to: original)
            try #require(chmod(source.path, 0) == 0)
            defer { _ = chmod(source.path, 0o600) }
            let before = try FileManager.default.contentsOfDirectory(atPath: volume.path)
            let outcome =
                move
                ? FileOperations.move(urls: [source], into: volume, onConflict: .replace)
                : FileOperations.copy(urls: [source], into: volume, onConflict: .replace)
            #expect(outcome.failures.count == 1)
            #expect(outcome.performed.isEmpty)
            #expect((try? Data(contentsOf: original)) == payload)
            #expect(FileManager.default.fileExists(atPath: source.path))
            let after = try FileManager.default.contentsOfDirectory(atPath: volume.path)
            #expect(Set(before) == Set(after))
        }
    }

    @Test(arguments: [false, true]) func undoReplaceRestoresOriginalSpelling(_ move: Bool) throws {
        try withVolume { scratch, volume in
            let source = scratch.appendingPathComponent("ITEM")
            let original = volume.appendingPathComponent("item")
            let replacement = Data("replacement".utf8)
            try replacement.write(to: source)
            try payload.write(to: original)
            let applied =
                move
                ? FileOperations.move(urls: [source], into: volume, onConflict: .replace)
                : FileOperations.copy(urls: [source], into: volume, onConflict: .replace)
            try #require(applied.failures.isEmpty)
            try #require(applied.performed.count == 1)
            let firstUndo = FileOperations.undo(applied.performed)
            try #require(firstUndo.failures.isEmpty)
            func assertRestored() throws {
                let names = try FileManager.default.contentsOfDirectory(atPath: volume.path)
                #expect(names.contains("item"))
                #expect(!names.contains("ITEM"))
                #expect(try Data(contentsOf: original) == payload)
            }
            try assertRestored()
            let replay = FileOperations.redo(firstUndo.performed)
            try #require(replay.failures.isEmpty)
            try #require(FileOperations.undo(replay.performed).failures.isEmpty)
            try assertRestored()
        }
    }

    @Test func diskFullStopsAndRemovesPartialCopy() throws {
        try withVolume { scratch, volume in
            let source = scratch.appendingPathComponent("large")
            let destination = volume.appendingPathComponent("large")
            try Data(repeating: 0x41, count: 80 << 20).write(to: source)
            let before = try FileManager.default.contentsOfDirectory(atPath: volume.path)
            let start = ContinuousClock.now
            do {
                try ProgressiveCopy.copy(
                    from: source, to: destination, onBytes: { _ in },
                    shouldCancel: { start.duration(to: .now) > .seconds(5) })
                Issue.record("Copy unexpectedly succeeded")
            } catch {
                #expect((error as NSError).domain == NSPOSIXErrorDomain)
                #expect((error as NSError).code == Int(ENOSPC))
            }
            #expect(start.duration(to: .now) < .seconds(5))
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            let after = try FileManager.default.contentsOfDirectory(atPath: volume.path)
            #expect(Set(before) == Set(after))
        }
    }

    private func withScratch(_ body: (URL) throws -> Void) throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pathem-xvol-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try body(scratch)
    }

    private func withVolume(_ body: (URL, URL) throws -> Void) throws {
        try withScratch { scratch in
            let image = scratch.appendingPathComponent("fixture.dmg")
            let mount = scratch.appendingPathComponent("mount")
            guard
                Self.run(
                    "/usr/bin/hdiutil",
                    [
                        "create", "-size", "64m", "-fs", "APFS", "-volname", "PathemTest",
                        image.path,
                    ]),
                Self.run(
                    "/usr/bin/hdiutil",
                    [
                        "attach", "-nobrowse", "-owners", "on", "-mountpoint", mount.path,
                        image.path,
                    ])
            else {
                print(
                    "Skipping cross-volume fixture: hdiutil could not create or attach a 64 MB APFS image"
                )
                return
            }
            defer {
                if !Self.run("/usr/bin/hdiutil", ["detach", mount.path]) {
                    Issue.record("Unable to detach the scratch APFS image")
                }
            }
            try body(scratch, mount)
        }
    }

    private static func run(_ path: String, _ args: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
