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

    /// A folder with `a.txt` and `b.txt` as two names for one inode, an unrelated file, and
    /// `nested/escaped.txt` hard-linked to a file outside the folder.
    private func makeLinkedTree(in scratch: URL) throws -> URL {
        let tree = scratch.appendingPathComponent("linked")
        let nested = tree.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let first = tree.appendingPathComponent("a.txt")
        try Data(repeating: 0x61, count: 200_000).write(to: first)
        try #require(link(first.path, tree.appendingPathComponent("b.txt").path) == 0)
        try payload.write(to: tree.appendingPathComponent("other.txt"))
        let outside = scratch.appendingPathComponent("outside.txt")
        try payload.write(to: outside)
        try #require(link(outside.path, nested.appendingPathComponent("escaped.txt").path) == 0)
        return tree
    }

    private func info(_ url: URL) throws -> stat {
        var value = stat()
        try #require(lstat(url.path, &value) == 0, "lstat \(url.path)")
        return value
    }

    private func expectLinkedTree(at copy: URL, sourceInode: ino_t?) throws {
        let a = try info(copy.appendingPathComponent("a.txt"))
        let b = try info(copy.appendingPathComponent("b.txt"))
        #expect(a.st_ino == b.st_ino)
        #expect(a.st_nlink == 2)
        #expect(b.st_nlink == 2)
        if let sourceInode { #expect(a.st_ino != sourceInode) }
        let bytes = Data(repeating: 0x61, count: 200_000)
        #expect(try Data(contentsOf: copy.appendingPathComponent("a.txt")) == bytes)
        #expect(try Data(contentsOf: copy.appendingPathComponent("b.txt")) == bytes)
        #expect(try Data(contentsOf: copy.appendingPathComponent("other.txt")) == payload)
        #expect(try info(copy.appendingPathComponent("other.txt")).st_nlink == 1)
        // The other name of this inode is outside the copied folder, so it stays independent.
        let escaped = copy.appendingPathComponent("nested/escaped.txt")
        #expect(try Data(contentsOf: escaped) == payload)
        #expect(try info(escaped).st_nlink == 1)
    }

    @Test func copyKeepsHardLinksInsideAFolder() throws {
        try withScratch { scratch in
            let tree = try makeLinkedTree(in: scratch)
            let sourceInode = try info(tree.appendingPathComponent("a.txt")).st_ino
            let destination = scratch.appendingPathComponent("destination")
            try FileManager.default.createDirectory(
                at: destination, withIntermediateDirectories: false)
            var reported: [Int64] = []
            var total: Int64 = 0
            let outcome = FileOperations.copy(
                urls: [tree], into: destination, verify: true,
                report: {
                    reported.append($0.completedBytes)
                    total = $0.totalBytes
                })
            #expect(outcome.failures.isEmpty)
            #expect(outcome.performed.count == 1)
            try expectLinkedTree(
                at: destination.appendingPathComponent("linked"), sourceInode: sourceInode)
            // The source pair is untouched and still not linked to the copy.
            #expect(try info(tree.appendingPathComponent("a.txt")).st_nlink == 2)
            #expect(try info(tree.appendingPathComponent("b.txt")).st_ino == sourceInode)
            #expect(reported == reported.sorted())
            #expect(reported.last == total)
            #expect(
                try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["linked"])
        }
    }

    @Test func moveAcrossVolumesKeepsHardLinksInsideAFolder() throws {
        try withVolume { scratch, volume in
            let tree = try makeLinkedTree(in: scratch)
            let outcome = FileOperations.move(urls: [tree], into: volume)
            #expect(outcome.failures.isEmpty)
            #expect(outcome.performed.count == 1)
            try expectLinkedTree(at: volume.appendingPathComponent("linked"), sourceInode: nil)
            // Both source names passed the per-item size and type guard and were removed.
            #expect(!FileManager.default.fileExists(atPath: tree.path))
            #expect(try Data(contentsOf: scratch.appendingPathComponent("outside.txt")) == payload)
            #expect(try info(scratch.appendingPathComponent("outside.txt")).st_nlink == 1)
        }
    }

    /// A scripted hdiutil: `busy` plain detaches fail first, `forceOnly` needs -force, and
    /// `stuck` never detaches.
    private final class FakeImages {
        var attached = true
        var busy = 0
        var forceOnly = false
        var stuck = false
        var lies = false  // detach always exits nonzero, even when it worked
        var infoWorks = true
        var calls: [[String]] = []
        var pauses: [TimeInterval] = []

        var fixture: ScratchImage {
            ScratchImage(
                hdiutil: { [self] args in
                    if args.first == "info" {
                        let images: [[String: Any]] =
                            attached
                            ? [
                                [
                                    "image-path": "/tmp/other.dmg",
                                    "system-entities": [["dev-entry": "/dev/disk7"]],
                                ],
                                [
                                    "image-path": "/tmp/fixture.dmg",
                                    "system-entities": [
                                        ["dev-entry": "/dev/disk9s1"], ["dev-entry": "/dev/disk9"],
                                        ["dev-entry": "/dev/disk10"],
                                    ],
                                ],
                            ] : []
                        let plist = try! PropertyListSerialization.data(
                            fromPropertyList: ["images": images], format: .xml, options: 0)
                        return (infoWorks, infoWorks ? plist : Data())
                    }
                    calls.append(args)
                    let force = args.contains("-force")
                    if busy > 0, !force {
                        busy -= 1
                        return (false, Data())
                    }
                    if stuck || (forceOnly && !force) { return (false, Data()) }
                    attached = false
                    return (!lies, Data())
                },
                pause: { [self] in pauses.append($0) })
        }

        func detach() -> Bool {
            fixture.detach(
                image: URL(fileURLWithPath: "/tmp/fixture.dmg"),
                mount: URL(fileURLWithPath: "/tmp/pathem-xvol-absent/mount"))
        }
    }

    @Test func detachRetriesABusyImageWithBackoff() {
        let images = FakeImages()
        images.busy = 2
        #expect(images.detach())
        // Only this image's whole disk is detached, never another image's device.
        #expect(images.calls == Array(repeating: ["detach", "/dev/disk9"], count: 3))
        #expect(images.pauses == [0.2, 0.5])
    }

    @Test func detachForcesAfterTheRetriesRunOut() {
        let images = FakeImages()
        images.forceOnly = true
        #expect(images.detach())
        #expect(images.pauses == [0.2, 0.5, 1, 2])
        #expect(images.calls.count == 6)
        #expect(images.calls.last == ["detach", "-force", "/dev/disk9"])
        #expect(images.calls.dropLast().allSatisfy { $0 == ["detach", "/dev/disk9"] })
    }

    @Test func detachFailsOnlyWhenTheImageIsStillAttached() {
        let stuck = FakeImages()
        stuck.stuck = true  // even the forced detach leaves it attached
        #expect(!stuck.detach())
        #expect(stuck.calls.last == ["detach", "-force", "/dev/disk9"])
        #expect(stuck.attached)

        // A detach that exits nonzero but released the image is a success, with no retry.
        let lying = FakeImages()
        lying.lies = true
        #expect(lying.detach())
        #expect(lying.calls == [["detach", "/dev/disk9"]])
        #expect(lying.pauses.isEmpty)

        // Nothing attached (a failed create or attach): no detach call at all.
        let absent = FakeImages()
        absent.attached = false
        #expect(absent.detach())
        #expect(absent.calls.isEmpty)
        // The same when hdiutil cannot list images and the mount point is not a volume.
        absent.infoWorks = false
        #expect(absent.detach())
        #expect(absent.calls.isEmpty)
    }

    /// The real thing: an open file keeps the volume busy, so only the forced detach works.
    @Test func detachForcesARealBusyImage() throws {
        var fixture = ScratchImage.live
        fixture.backoff = [0.1]
        var calls: [[String]] = []
        let hdiutil = fixture.hdiutil
        fixture.hdiutil = {
            if $0.first == "detach" { calls.append($0) }
            return hdiutil($0)
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pathem-xvol-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        let image = scratch.appendingPathComponent("fixture.dmg")
        let mount = scratch.appendingPathComponent("mount")
        var held: FileHandle?
        defer {
            try? held?.close()
            if fixture.detach(image: image, mount: mount) {
                try? FileManager.default.removeItem(at: scratch)
            }
        }
        guard
            fixture.hdiutil([
                "create", "-size", "64m", "-fs", "APFS", "-volname", "PathemTest", image.path,
            ]).ok,
            fixture.hdiutil(["attach", "-nobrowse", "-mountpoint", mount.path, image.path]).ok
        else {
            print("Skipping busy-image fixture: hdiutil could not create or attach an image")
            return
        }
        #expect(fixture.devices(for: image)?.count == 1)
        #expect(ScratchImage.isMountPoint(mount))
        let file = mount.appendingPathComponent("held.txt")
        try payload.write(to: file)
        held = try FileHandle(forReadingFrom: file)

        #expect(fixture.detach(image: image, mount: mount))
        #expect(fixture.devices(for: image) == [])
        #expect(!ScratchImage.isMountPoint(mount))
        // Guaranteed: plain detaches fail while the file is held, and only a forced one releases
        // it. The number of retries is timing dependent, so it is not asserted.
        #expect(calls.first?.contains("-force") == false)
        #expect(calls.last?.contains("-force") == true)
        #expect(calls.filter { $0.contains("-force") }.count >= 1)
    }

    private func withScratch(_ body: (URL) throws -> Void) throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pathem-xvol-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try body(scratch)
    }

    private func withVolume(_ body: (URL, URL) throws -> Void) throws {
        // Not withScratch: the folder holds the image, so it goes only after a clean detach.
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pathem-xvol-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        let image = scratch.appendingPathComponent("fixture.dmg")
        let mount = scratch.appendingPathComponent("mount")
        let fixture = ScratchImage.live
        defer {
            if fixture.detach(image: image, mount: mount) {
                try? FileManager.default.removeItem(at: scratch)
            } else {
                Issue.record(
                    "Unable to detach the scratch APFS image; it is still attached at \(mount.path)"
                )
            }
        }
        guard
            fixture.hdiutil([
                "create", "-size", "64m", "-fs", "APFS", "-volname", "PathemTest", image.path,
            ]).ok,
            fixture.hdiutil([
                "attach", "-nobrowse", "-owners", "on", "-mountpoint", mount.path, image.path,
            ]).ok
        else {
            // The deferred detach also releases an image that attached but failed to mount.
            print(
                "Skipping cross-volume fixture: hdiutil could not create or attach a 64 MB APFS image"
            )
            return
        }
        try body(scratch, mount)
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

/// Teardown for the scratch disk image. The hdiutil runner and the pause are injected so the
/// retry and force logic can be tested without a real image.
struct ScratchImage {
    var hdiutil: ([String]) -> (ok: Bool, output: Data)
    var pause: (TimeInterval) -> Void
    /// Waits before each plain retry. A new volume is often briefly busy with indexing.
    var backoff: [TimeInterval] = [0.2, 0.5, 1, 2]

    static var live: ScratchImage {
        ScratchImage(
            hdiutil: { args in
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                process.arguments = args
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else { return (false, Data()) }
                let output = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return (process.terminationStatus == 0, output)
            },
            pause: { Thread.sleep(forTimeInterval: $0) })
    }

    /// Device nodes still backed by `image`, whole disk first. Nil when hdiutil cannot say.
    func devices(for image: URL) -> [String]? {
        let info = hdiutil(["info", "-plist"])
        guard info.ok,
            let plist = try? PropertyListSerialization.propertyList(from: info.output, format: nil)
                as? [String: Any],
            let images = plist["images"] as? [[String: Any]]
        else { return nil }
        let wanted = image.resolvingSymlinksInPath().path
        return images.filter {
            ($0["image-path"] as? String).map {
                URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == wanted
            } ?? false
        }.compactMap { record in
            (record["system-entities"] as? [[String: Any]] ?? [])
                .compactMap { $0["dev-entry"] as? String }
                .min { ($0.count, $0) < ($1.count, $1) }
        }
    }

    /// Detach `image`: plain attempts with a backoff, then `-force`. True unless the image is
    /// still attached afterward, so a detach that reports an error but worked is not a failure.
    func detach(image: URL, mount: URL) -> Bool {
        // Without device info, fall back to whether `mount` is still a separate volume.
        func gone() -> Bool { devices(for: image)?.isEmpty ?? !Self.isMountPoint(mount) }
        func attempt(_ flags: [String]) {
            for target in devices(for: image) ?? [mount.path] {
                _ = hdiutil(["detach"] + flags + [target])
            }
        }
        for delay in [0] + backoff {
            if gone() { return true }
            if delay > 0 { pause(delay) }
            attempt([])
        }
        if gone() { return true }
        // A forced detach can return before diskarbitrationd has torn the volume down, so under
        // load the image is still listed for a moment. Wait a bounded time, forcing once more.
        for _ in 0..<3 {
            attempt(["-force"])
            for _ in 0..<5 {
                if gone() { return true }
                pause(0.5)
            }
        }
        return gone()
    }

    static func isMountPoint(_ url: URL) -> Bool {
        var own = stat()
        var parent = stat()
        guard lstat(url.path, &own) == 0,
            lstat(url.deletingLastPathComponent().path, &parent) == 0
        else { return false }
        return own.st_dev != parent.st_dev
    }
}
