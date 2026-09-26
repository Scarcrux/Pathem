#if DEBUG
import Foundation
import PathemEngine

/// Product-boundary checks for deterministic feature families that are otherwise covered only by
/// engine tests. These run inside the built Pathem executable, use real files and subprocesses, and
/// print the same RESULT contract as the other black-box scenarios.
enum DeterministicE2E {
    enum Suite: String {
        case files = "PATHEM_FILES_E2E"
        case advancedFilesystem = "PATHEM_ADVANCED_FILES_E2E"
        case archives = "PATHEM_ARCHIVES_E2E"
        case searchMetadata = "PATHEM_SEARCH_METADATA_E2E"
        case developerTools = "PATHEM_DEVELOPER_E2E"
        case remoteWebDAV = "PATHEM_WEBDAV_E2E"
        case remoteObjectStorage = "PATHEM_OBJECT_STORAGE_E2E"
    }

    static var requestedSuite: Suite? {
        let env = ProcessInfo.processInfo.environment
        return [
            Suite.files, .advancedFilesystem, .archives, .searchMetadata, .developerTools,
            .remoteWebDAV, .remoteObjectStorage,
        ]
        .first { env[$0.rawValue] != nil }
    }

    @MainActor
    static func start(_ suite: Suite) {
        Task {
            var report = Report(title: suite.rawValue)
            do {
                switch suite {
                case .files: try runFiles(&report)
                case .advancedFilesystem: try runAdvancedFilesystem(&report)
                case .archives: try await runArchives(&report)
                case .searchMetadata: try await runSearchMetadata(&report)
                case .developerTools: try await runDeveloperTools(&report)
                case .remoteWebDAV: try await runWebDAV(&report)
                case .remoteObjectStorage: try await runObjectStorage(&report)
                }
            } catch {
                report.check("scenario-completed", false, String(describing: error))
            }
            report.finish()
        }
    }

    private struct Report {
        let title: String
        private(set) var checks: [(String, Bool, String)] = []

        mutating func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            checks.append((name, ok, detail))
        }

        func finish() -> Never {
            print("=== \(title) ===")
            for (name, ok, detail) in checks {
                print("\(ok ? "ok  " : "FAIL") \(name)\(detail.isEmpty ? "" : " (\(detail))")")
            }
            let ok = !checks.isEmpty && checks.allSatisfy(\.1)
            print("RESULT: \(ok ? "PASS" : "FAIL") (\(checks.count) checks)")
            exit(ok ? 0 : 1)
        }
    }

    private static func workspace(_ tag: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pathem-\(tag)-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func text(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    private static func runFiles(_ report: inout Report) throws {
        let fm = FileManager.default
        let root = try workspace("files")
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        let sourceReport = source.appendingPathComponent("report.txt")
        let destinationReport = destination.appendingPathComponent("report.txt")
        try "new-version".write(to: sourceReport, atomically: true, encoding: .utf8)
        try "old-version".write(to: destinationReport, atomically: true, encoding: .utf8)
        let skipped = FileOperations.copy(
            urls: [sourceReport], into: destination, onConflict: .skip)
        report.check(
            "copy-skip-preserves-both-files",
            skipped.performed.isEmpty && skipped.failures.isEmpty
                && skipped.skipped == ["report.txt"] && text(sourceReport) == "new-version"
                && text(destinationReport) == "old-version")
        let copied = FileOperations.copy(
            urls: [sourceReport], into: destination, onConflict: .replace, verify: true)
        report.check(
            "copy-replace-verifies-bytes",
            copied.performed.count == 1 && copied.failures.isEmpty
                && text(destinationReport) == "new-version")

        let undoneCopy = FileOperations.undo(copied.performed)
        report.check(
            "copy-replace-undo-restores-original",
            undoneCopy.failures.isEmpty && text(destinationReport) == "old-version"
                && text(sourceReport) == "new-version")
        let redoneCopy = FileOperations.redo(copied.performed)
        report.check(
            "copy-replace-redo-reapplies",
            redoneCopy.performed.count == 1 && redoneCopy.failures.isEmpty
                && text(destinationReport) == "new-version")
        _ = FileOperations.undo(redoneCopy.performed)

        let sourceMove = source.appendingPathComponent("item.txt")
        let existingMove = destination.appendingPathComponent("item.txt")
        try "moving".write(to: sourceMove, atomically: true, encoding: .utf8)
        try "existing".write(to: existingMove, atomically: true, encoding: .utf8)
        let moved = FileOperations.move(
            urls: [sourceMove], into: destination, onConflict: .keepBoth)
        let movedURL = moved.performed.first?.destination
        report.check(
            "move-keep-both-does-not-clobber",
            moved.failures.isEmpty && movedURL?.lastPathComponent == "item copy.txt"
                && text(existingMove) == "existing" && movedURL.flatMap(text) == "moving"
                && !fm.fileExists(atPath: sourceMove.path))
        let undoneMove = FileOperations.undo(moved.performed)
        report.check(
            "move-undo-restores-source",
            undoneMove.failures.isEmpty && text(sourceMove) == "moving"
                && !(movedURL.map { fm.fileExists(atPath: $0.path) } ?? true))
        let redoneMove = FileOperations.redo(moved.performed)
        report.check(
            "move-redo-reapplies",
            redoneMove.failures.isEmpty && !fm.fileExists(atPath: sourceMove.path)
                && movedURL.flatMap(text) == "moving")
        _ = FileOperations.undo(redoneMove.performed)

        let cancelledSource = source.appendingPathComponent("cancelled.txt")
        try "do-not-copy".write(to: cancelledSource, atomically: true, encoding: .utf8)
        let cancelled = FileOperations.copy(
            urls: [cancelledSource], into: destination, shouldCancel: { true })
        report.check(
            "copy-cancel-stops-before-mutation",
            cancelled.performed.isEmpty && cancelled.failures.isEmpty
                && fm.fileExists(atPath: cancelledSource.path)
                && !fm.fileExists(
                    atPath: destination.appendingPathComponent("cancelled.txt").path)
        )

        let trashCandidate = root.appendingPathComponent("trash-roundtrip-\(UUID().uuidString).txt")
        try "recover-me".write(to: trashCandidate, atomically: true, encoding: .utf8)
        let trashed = FileOperations.trash(urls: [trashCandidate])
        report.check(
            "trash-moves-real-file",
            trashed.trashed.count == 1 && trashed.failures.isEmpty
                && !fm.fileExists(atPath: trashCandidate.path)
                && trashed.trashed.allSatisfy { fm.fileExists(atPath: $0.trashed.path) })
        let restored = FileOperations.untrash(trashed.trashed)
        report.check(
            "trash-put-back-restores-bytes",
            restored.failures.isEmpty && restored.restored == [trashCandidate]
                && text(trashCandidate) == "recover-me")
    }

    private static func runAdvancedFilesystem(_ report: inout Report) throws {
        let fm = FileManager.default
        let root = try workspace("advanced-files")
        defer { try? fm.removeItem(at: root) }

        let batch = root.appendingPathComponent("batch", isDirectory: true)
        try fm.createDirectory(at: batch, withIntermediateDirectories: true)
        let fileNames = BatchCreate.expand("note_{01..03}.txt\nnote_02.txt\ninvalid/name")
        let createdFiles = BatchCreate.create(fileNames, kind: .files, in: batch)
        let folderNames = BatchCreate.expand("Report {2..1}")
        let createdFolders = BatchCreate.create(folderNames, kind: .folders, in: batch)
        let repeatedCreate = BatchCreate.create(fileNames, kind: .files, in: batch)
        report.check(
            "batch-create-expands-dedupes-and-skips-existing",
            createdFiles.created == ["note_01.txt", "note_02.txt", "note_03.txt"]
                && createdFiles.failures.isEmpty
                && createdFolders.created == ["Report 2", "Report 1"]
                && createdFolders.failures.isEmpty && repeatedCreate.created.isEmpty)

        let first = batch.appendingPathComponent("note_01.txt")
        let second = batch.appendingPathComponent("note_02.txt")
        try "first".write(to: first, atomically: true, encoding: .utf8)
        try "second".write(to: second, atomically: true, encoding: .utf8)
        let renamed = BatchRename.perform(
            in: batch,
            pairs: [
                RenamePair(original: "note_01.txt", renamed: "note_02.txt"),
                RenamePair(original: "note_02.txt", renamed: "note_01.txt"),
            ])
        report.check(
            "batch-rename-two-phase-swap-preserves-bytes",
            renamed.renamed == 2 && renamed.failures.isEmpty && text(first) == "second"
                && text(second) == "first")

        let linkTarget = root.appendingPathComponent("link-target.txt")
        try "linked".write(to: linkTarget, atomically: true, encoding: .utf8)
        let symlinked = FileOperations.makeLinks([linkTarget], kind: .symlink)
        let hardlinked = FileOperations.makeLinks([linkTarget], kind: .hardlink)
        let aliased = FileOperations.makeLinks([linkTarget], kind: .alias)
        let symlink = root.appendingPathComponent("link-target symlink.txt")
        let hardlink = root.appendingPathComponent("link-target hardlink.txt")
        let alias = root.appendingPathComponent("link-target alias.txt")
        let symlinkDestination = try fm.destinationOfSymbolicLink(atPath: symlink.path)
        let aliasDestination = try URL(resolvingAliasFileAt: alias).standardizedFileURL
        try "shared-inode".write(to: hardlink, atomically: false, encoding: .utf8)
        report.check(
            "symbolic-hard-and-alias-links-resolve",
            symlinked.failures.isEmpty && hardlinked.failures.isEmpty && aliased.failures.isEmpty
                && symlinkDestination == linkTarget.path && text(linkTarget) == "shared-inode"
                && aliasDestination == linkTarget.standardizedFileURL)

        let duplicates = root.appendingPathComponent("duplicates", isDirectory: true)
        try fm.createDirectory(at: duplicates, withIntermediateDirectories: true)
        let duplicateBytes = Data(repeating: 0x61, count: 128)
        try duplicateBytes.write(to: duplicates.appendingPathComponent("a.bin"))
        try duplicateBytes.write(to: duplicates.appendingPathComponent("b.bin"))
        try Data(repeating: 0x62, count: 128).write(
            to: duplicates.appendingPathComponent("same-size-different.bin"))
        let duplicateGroups = DuplicateFinder.find(in: [duplicates])
        report.check(
            "duplicate-finder-confirms-content-not-just-size",
            duplicateGroups.count == 1
                && Set(duplicateGroups[0].files.map(\.name)) == ["a.bin", "b.bin"])

        let sized = root.appendingPathComponent("sized", isDirectory: true)
        let nested = sized.appendingPathComponent("nested", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 10).write(to: sized.appendingPathComponent("ten.bin"))
        try Data(repeating: 2, count: 20).write(to: nested.appendingPathComponent("twenty.bin"))
        try fm.createSymbolicLink(
            at: sized.appendingPathComponent("nested-link"), withDestinationURL: nested)
        let measured = DirectorySize.total(of: sized)
        let ranked = DiskUsage.rankedChildren(of: sized)
        let rankedByName = Dictionary(uniqueKeysWithValues: ranked.map { ($0.name, $0) })
        report.check(
            "directory-size-and-disk-usage-do-not-follow-symlinks",
            measured.complete && measured.bytes == 30 && rankedByName["nested"]?.bytes == 20
                && rankedByName["nested"]?.isDirectory == true
                && rankedByName["nested-link"]?.isDirectory == false,
            "measured=\(measured.bytes)/\(measured.complete) ranked=\(ranked.map { "\($0.name):\($0.bytes)" })"
        )

        let left = root.appendingPathComponent("sync-left", isDirectory: true)
        let right = root.appendingPathComponent("sync-right", isDirectory: true)
        try fm.createDirectory(at: left, withIntermediateDirectories: true)
        try fm.createDirectory(at: right, withIntermediateDirectories: true)
        try "from-left".write(
            to: left.appendingPathComponent("left.txt"), atomically: true, encoding: .utf8)
        try "from-right".write(
            to: right.appendingPathComponent("right.txt"), atomically: true, encoding: .utf8)
        try "left-conflict".write(
            to: left.appendingPathComponent("conflict.txt"), atomically: true, encoding: .utf8)
        try "right-conflict".write(
            to: right.appendingPathComponent("conflict.txt"), atomically: true, encoding: .utf8)
        let skippedPlan = FolderSync.plan(
            left: left, right: right, conflict: .skip, byContent: true)
        let synced = FolderSync.execute(skippedPlan, left: left, right: right)
        report.check(
            "two-way-sync-copies-additions-and-skips-conflicts",
            synced.copiedToRight == 1 && synced.copiedToLeft == 1
                && synced.conflictsSkipped == 1 && synced.failures.isEmpty
                && text(right.appendingPathComponent("left.txt")) == "from-left"
                && text(left.appendingPathComponent("right.txt")) == "from-right"
                && text(left.appendingPathComponent("conflict.txt")) == "left-conflict"
                && text(right.appendingPathComponent("conflict.txt")) == "right-conflict")

        let attributeTarget = root.appendingPathComponent("attributes.txt")
        try "attributes".write(to: attributeTarget, atomically: true, encoding: .utf8)
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let attributes = BulkAttributes.apply(
            .init(modificationDate: fixedDate, posixPermissions: 0o600, addTags: ["Bulk-E2E"]),
            to: [attributeTarget])
        let values = try attributeTarget.resourceValues(forKeys: [.contentModificationDateKey])
        let mode =
            (try fm.attributesOfItem(atPath: attributeTarget.path)[.posixPermissions]
            as? NSNumber)?.uint16Value
        report.check(
            "bulk-attributes-update-date-permissions-and-tags",
            attributes.changed == 1 && attributes.failures.isEmpty && mode == 0o600
                && abs(
                    (values.contentModificationDate?.timeIntervalSince1970 ?? 0)
                        - fixedDate.timeIntervalSince1970) < 1
                && FileTags.tags(of: attributeTarget).contains { $0.name == "Bulk-E2E" })
    }

    private static func runArchives(_ report: inout Report) async throws {
        let fm = FileManager.default
        let root = try workspace("archives")
        defer { try? fm.removeItem(at: root) }
        let payload = root.appendingPathComponent("payload", isDirectory: true)
        try fm.createDirectory(at: payload, withIntermediateDirectories: true)
        let original = payload.appendingPathComponent("alpha.txt")
        try "alpha-v1".write(to: original, atomically: true, encoding: .utf8)
        let archive = root.appendingPathComponent("payload.zip")
        try await Archiver.compress([payload], to: archive)
        let listing = try await Archiver.list(archive)
        report.check(
            "archive-create-and-list",
            fm.fileExists(atPath: archive.path)
                && listing.contains(where: { $0.hasSuffix("payload/alpha.txt") }))

        let extracted = root.appendingPathComponent("extracted", isDirectory: true)
        try await Archiver.extract(archive, to: extracted)
        let extractedFile = extracted.appendingPathComponent("payload/alpha.txt")
        report.check("archive-extract-preserves-bytes", text(extractedFile) == "alpha-v1")
        try "alpha-v2".write(to: extractedFile, atomically: true, encoding: .utf8)
        try await Archiver.repack(from: extracted, into: archive)
        let repacked = root.appendingPathComponent("repacked", isDirectory: true)
        try await Archiver.extract(archive, to: repacked)
        report.check(
            "archive-repack-persists-edit",
            text(repacked.appendingPathComponent("payload/alpha.txt")) == "alpha-v2")

        let crossA = root.appendingPathComponent("cross-a", isDirectory: true)
        let crossB = root.appendingPathComponent("cross-b", isDirectory: true)
        try fm.createDirectory(at: crossA, withIntermediateDirectories: true)
        try fm.createDirectory(at: crossB, withIntermediateDirectories: true)
        let crossAFile = crossA.appendingPathComponent("one.txt")
        let crossBFile = crossB.appendingPathComponent("two.txt")
        try "one".write(to: crossAFile, atomically: true, encoding: .utf8)
        try "two".write(to: crossBFile, atomically: true, encoding: .utf8)
        let crossArchive = root.appendingPathComponent("cross-folder.zip")
        try await Archiver.compressItems([crossAFile, crossBFile], to: crossArchive)
        let crossExtracted = root.appendingPathComponent("cross-extracted", isDirectory: true)
        try await Archiver.extract(crossArchive, to: crossExtracted)
        report.check(
            "cross-folder-archive-stages-every-source",
            text(crossExtracted.appendingPathComponent("one.txt")) == "one"
                && text(crossExtracted.appendingPathComponent("two.txt")) == "two")

        let sevenZip = root.appendingPathComponent("native.7z")
        try await Archiver.compress7z([original], to: sevenZip)
        let sevenZipListing = try await Archiver.list(sevenZip)
        let sevenZipExtracted = root.appendingPathComponent("seven-extracted", isDirectory: true)
        try await Archiver.extract(sevenZip, to: sevenZipExtracted)
        report.check(
            "seven-zip-create-list-extract",
            sevenZipListing.contains { $0.hasSuffix("alpha.txt") }
                && text(sevenZipExtracted.appendingPathComponent("alpha.txt")) == "alpha-v1")

        let bytes = Data((0..<131_111).map { UInt8($0 % 251) })
        let splitSource = root.appendingPathComponent("large.bin")
        try bytes.write(to: splitSource)
        let parts = try FileSplitter.split(splitSource, partSize: 32_768)
        let merged = try FileSplitter.merge(
            firstPart: parts[0], into: root.appendingPathComponent("merged.bin"))
        report.check(
            "split-merge-roundtrip",
            parts.count == 5 && (try? Data(contentsOf: merged)) == bytes)

        let backupDir = root.appendingPathComponent("backup", isDirectory: true)
        let backup = Backup.backup([original], to: backupDir)
        report.check(
            "backup-copies-real-bytes",
            backup.failures.isEmpty && backup.succeeded.count == 1
                && text(backupDir.appendingPathComponent("alpha.txt")) == "alpha-v1")

        let doomed = root.appendingPathComponent("shred.txt")
        try Data(repeating: 0x5a, count: 96_000).write(to: doomed)
        let shredded = SecureDelete.shred([doomed])
        report.check(
            "secure-delete-removes-file",
            shredded.failures.isEmpty && shredded.deleted == ["shred.txt"]
                && !fm.fileExists(atPath: doomed.path))

        let image = try await DiskImage.createEncrypted(
            from: [original], volumeName: "Pathem-E2E", password: "deterministic-test-password",
            in: root)
        report.check(
            "encrypted-disk-image-created",
            DiskImage.isDiskImage(image)
                && ((try? image.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0)

        let damaged = root.appendingPathComponent("damaged.zip")
        try Data("not-a-zip".utf8).write(to: damaged)
        let failedDestination = root.appendingPathComponent("failed-extract", isDirectory: true)
        try fm.createDirectory(at: failedDestination, withIntermediateDirectories: true)
        let sentinel = failedDestination.appendingPathComponent("existing.txt")
        try "untouched".write(to: sentinel, atomically: true, encoding: .utf8)
        var damagedArchiveFailed = false
        do {
            try await Archiver.extract(damaged, to: failedDestination)
        } catch {
            damagedArchiveFailed = true
        }
        report.check(
            "damaged-archive-fails-without-clobbering-existing-files",
            damagedArchiveFailed && text(sentinel) == "untouched")
    }

    private static func runSearchMetadata(_ report: inout Report) async throws {
        let fm = FileManager.default
        let root = try workspace("search-metadata")
        defer { try? fm.removeItem(at: root) }
        let first = root.appendingPathComponent("first.txt")
        let second = root.appendingPathComponent("second.md")
        let binary = root.appendingPathComponent("binary.dat")
        try "Needle one\nplain".write(to: first, atomically: true, encoding: .utf8)
        try "needle two\nneedle three".write(to: second, atomically: true, encoding: .utf8)
        let binaryBytes = Data([0, 110, 101, 101, 100, 108, 101, 0, 255])
        try binaryBytes.write(to: binary)

        let literal = await ContentSearch.search("needle", in: root)
        report.check(
            "content-search-finds-real-files",
            literal.count == 3
                && Set(literal.map { URL(fileURLWithPath: $0.path).lastPathComponent })
                    == ["first.txt", "second.md"]
        )
        let regex = await ContentSearch.search("Needle (one|two)", in: root, regex: true)
        report.check(
            "content-regex-search-runs", regex.count == 2,
            "count=\(regex.count) matches=\(regex.map { "\(URL(fileURLWithPath: $0.path).lastPathComponent):\($0.line)" })"
        )
        let replaced = await ContentSearch.replaceAll("needle", with: "found", in: root)
        report.check(
            "content-replace-updates-real-files",
            replaced.filesChanged == 2 && replaced.replacements == 3
                && text(second) == "found two\nfound three"
                && (try? Data(contentsOf: binary)) == binaryBytes)

        try FileTags.setTags([FileTag(name: "E2E", color: .blue)], on: first)
        report.check(
            "finder-tags-roundtrip",
            FileTags.tags(of: first) == [FileTag(name: "E2E", color: .blue)])
        try FileMetadata.setFinderComment("coverage-marker", on: first)
        report.check(
            "finder-comment-roundtrip",
            FileMetadata.finderComment(of: first) == "coverage-marker")
        try FileTags.setTags([], on: first)
        try FileMetadata.setFinderComment("", on: first)
        report.check(
            "finder-metadata-clear-roundtrip",
            FileTags.tags(of: first).isEmpty && FileMetadata.finderComment(of: first) == nil)
        let hashBefore = try FileHasher.hash(first)
        let duplicate = root.appendingPathComponent("duplicate.txt")
        try fm.copyItem(at: first, to: duplicate)
        report.check(
            "hash-identifies-identical-content",
            hashBefore.count == 64 && (try? FileHasher.hash(duplicate)) == hashBefore)
    }

    private static func runDeveloperTools(_ report: inout Report) async throws {
        let fm = FileManager.default
        let root = try workspace("developer")
        defer { try? fm.removeItem(at: root) }
        let initResult = runProcess("/usr/bin/git", ["init", "-q", root.path])
        _ = runProcess("/usr/bin/git", ["-C", root.path, "config", "user.name", "Pathem E2E"])
        _ = runProcess(
            "/usr/bin/git",
            ["-C", root.path, "config", "user.email", "pathem-e2e@users.noreply.github.com"])
        report.check("git-repository-created", initResult.status == 0)

        let file = root.appendingPathComponent("source.swift")
        try "let answer = 42\n".write(to: file, atomically: true, encoding: .utf8)
        let dirty = await GitStatus.status(for: root)
        let untrackedSource =
            dirty?.states.contains {
                URL(fileURLWithPath: $0.key).standardizedFileURL.resolvingSymlinksInPath()
                    == file.standardizedFileURL.resolvingSymlinksInPath() && $0.value == .untracked
            } == true
        report.check(
            "git-status-sees-untracked-file",
            untrackedSource,
            "branch=\(dirty?.branch ?? "nil") state=\(String(describing: dirty?.states[file.path])) all=\(dirty?.states ?? [:])"
        )
        let staged = await GitOps.stageAll(in: root)
        let stagedDiff = await GitOps.stagedDiff(in: root)
        let hasStagedChanges = await GitOps.hasStagedChanges(in: root)
        report.check(
            "git-stage-and-diff",
            staged.ok && hasStagedChanges
                && stagedDiff.contains("source.swift") && stagedDiff.contains("answer"))
        let committed = await GitOps.commit("deterministic product E2E", in: root)
        let clean = await GitStatus.status(for: root)
        report.check(
            "git-commit-cleans-worktree",
            committed.ok && clean?.states.isEmpty == true)
        let emptyCommit = await GitOps.commit("should fail because tree is clean", in: root)
        let cleanAfterEmptyCommit = await GitStatus.status(for: root)
        report.check(
            "git-empty-commit-surfaces-failure",
            !emptyCommit.ok && cleanAfterEmptyCommit?.states.isEmpty == true)

        let command = ExternalCommand(
            id: "e2e", name: "E2E", command: "printf 'folder=%s file=%s' %D %N")
        let output = ExternalCommandRunner.run(command, files: [file], directory: root)
        report.check(
            "external-command-expands-and-runs",
            output.succeeded && output.text.contains("folder=\(root.path)")
                && output.text.contains("file=source.swift"))
    }

    private static func runWebDAV(_ report: inout Report) async throws {
        guard let rawPort = ProcessInfo.processInfo.environment["PATHEM_WEBDAV_PORT"],
            let port = Int(rawPort)
        else {
            throw NSError(
                domain: "PathemE2E", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "missing fixture port"])
        }
        let fm = FileManager.default
        let root = try workspace("webdav")
        defer { try? fm.removeItem(at: root) }
        let connection = RemoteConnection(
            name: "loopback", proto: .webdav, host: "127.0.0.1", port: port)
        let provider = RemoteProviders.make(for: .webdav)
        try await provider.makeDirectory(connection, path: "/docs", password: "")
        let upload = root.appendingPathComponent("upload.txt")
        try "webdav-roundtrip".write(to: upload, atomically: true, encoding: .utf8)
        try await provider.upload(
            upload, to: connection, remotePath: "/docs/upload.txt", password: "")
        let listed = try await provider.list(connection, path: "/docs", password: "")
        report.check(
            "webdav-create-upload-list",
            listed.contains { $0.name == "upload.txt" && !$0.isDirectory && $0.size == 16 })
        let download = root.appendingPathComponent("download.txt")
        try await provider.download(
            connection, remotePath: "/docs/upload.txt", to: download, password: "")
        report.check("webdav-download-preserves-bytes", text(download) == "webdav-roundtrip")
        var missingFailed = false
        do {
            try await provider.download(
                connection, remotePath: "/docs/missing.txt",
                to: root.appendingPathComponent("missing.txt"), password: "")
        } catch {
            missingFailed = true
        }
        report.check("webdav-missing-object-surfaces-error", missingFailed)
        try await provider.rename(
            connection, from: "/docs/upload.txt", to: "/docs/renamed.txt", password: "")
        let afterRename = try await provider.list(connection, path: "/docs", password: "")
        report.check(
            "webdav-rename",
            afterRename.contains { $0.name == "renamed.txt" }
                && !afterRename.contains { $0.name == "upload.txt" })
        try await provider.remove(
            connection, path: "/docs/renamed.txt", isDirectory: false, password: "")
        try await provider.remove(connection, path: "/docs", isDirectory: true, password: "")
        let rootListing = try await provider.list(connection, path: "/", password: "")
        report.check("webdav-delete-file-and-folder", !rootListing.contains { $0.name == "docs" })
    }

    private struct ObjectStorageResult {
        let listOK: Bool
        let downloadOK: Bool
        let renameOK: Bool
        let missingObjectFailed: Bool
        let invalidCredentialsFailed: Bool
        let cleanupOK: Bool
    }

    private static func runObjectStorage(_ report: inout Report) async throws {
        guard let rawPort = ProcessInfo.processInfo.environment["PATHEM_OBJECT_STORAGE_PORT"],
            let port = Int(rawPort)
        else {
            throw NSError(
                domain: "PathemE2E", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "missing object-storage fixture port"])
        }
        let root = try workspace("object-storage")
        defer { try? FileManager.default.removeItem(at: root) }

        let s3Connection = RemoteConnection(
            name: "loopback-s3", proto: .s3, host: "127.0.0.1", port: port,
            user: "e2e-access", region: "us-east-1")
        let s3 = try await objectStorageLifecycle(
            provider: RemoteProviders.make(for: .s3), connection: s3Connection,
            password: "e2e-secret", invalidPassword: "wrong-secret", container: "e2e-bucket",
            createContainer: false,
            localRoot: root.appendingPathComponent("s3", isDirectory: true),
            payload: "s3-roundtrip")
        report.check("s3-create-upload-list", s3.listOK)
        report.check("s3-download-preserves-bytes", s3.downloadOK)
        report.check("s3-copy-delete-rename", s3.renameOK)
        report.check("s3-missing-object-surfaces-error", s3.missingObjectFailed)
        report.check("s3-invalid-signature-is-rejected", s3.invalidCredentialsFailed)
        report.check("s3-delete-file-and-folder", s3.cleanupOK)

        let azureConnection = RemoteConnection(
            name: "loopback-azure", proto: .azure, host: "127.0.0.1", port: port,
            user: "devstoreaccount1")
        let azureKey = Data("e2e-azure-key".utf8).base64EncodedString()
        let azure = try await objectStorageLifecycle(
            provider: RemoteProviders.make(for: .azure), connection: azureConnection,
            password: azureKey,
            invalidPassword: Data("wrong-azure-key".utf8).base64EncodedString(),
            container: "e2econtainer", createContainer: true,
            localRoot: root.appendingPathComponent("azure", isDirectory: true),
            payload: "azure-roundtrip")
        report.check("azure-create-upload-list", azure.listOK)
        report.check("azure-download-preserves-bytes", azure.downloadOK)
        report.check("azure-copy-delete-rename", azure.renameOK)
        report.check("azure-missing-object-surfaces-error", azure.missingObjectFailed)
        report.check("azure-invalid-signature-is-rejected", azure.invalidCredentialsFailed)
        report.check("azure-delete-file-folder-container", azure.cleanupOK)
    }

    private static func objectStorageLifecycle(
        provider: RemoteProvider, connection: RemoteConnection, password: String,
        invalidPassword: String, container: String, createContainer: Bool, localRoot: URL,
        payload: String
    ) async throws -> ObjectStorageResult {
        let fm = FileManager.default
        try fm.createDirectory(at: localRoot, withIntermediateDirectories: true)
        if createContainer {
            try await provider.makeDirectory(connection, path: "/\(container)", password: password)
        }
        try await provider.makeDirectory(
            connection, path: "/\(container)/docs", password: password)
        let upload = localRoot.appendingPathComponent("upload.txt")
        try payload.write(to: upload, atomically: true, encoding: .utf8)
        try await provider.upload(
            upload, to: connection, remotePath: "/\(container)/docs/upload.txt",
            password: password)
        let listed = try await provider.list(
            connection, path: "/\(container)/docs/", password: password)
        let listOK = listed.contains {
            $0.name == "upload.txt" && !$0.isDirectory && $0.size == Int64(payload.utf8.count)
        }

        let download = localRoot.appendingPathComponent("download.txt")
        try await provider.download(
            connection, remotePath: "/\(container)/docs/upload.txt", to: download,
            password: password)
        let downloadOK = text(download) == payload

        try await provider.rename(
            connection, from: "/\(container)/docs/upload.txt",
            to: "/\(container)/docs/renamed.txt", password: password)
        let afterRename = try await provider.list(
            connection, path: "/\(container)/docs/", password: password)
        let renameOK =
            afterRename.contains { $0.name == "renamed.txt" }
            && !afterRename.contains { $0.name == "upload.txt" }

        var missingObjectFailed = false
        do {
            try await provider.download(
                connection, remotePath: "/\(container)/docs/missing.txt",
                to: localRoot.appendingPathComponent("missing.txt"), password: password)
        } catch {
            missingObjectFailed = true
        }
        var invalidCredentialsFailed = false
        do {
            _ = try await provider.list(
                connection, path: "/\(container)/docs/", password: invalidPassword)
        } catch {
            invalidCredentialsFailed = true
        }

        try await provider.remove(
            connection, path: "/\(container)/docs/renamed.txt", isDirectory: false,
            password: password)
        try await provider.remove(
            connection, path: "/\(container)/docs", isDirectory: true, password: password)
        if createContainer {
            try await provider.remove(
                connection, path: "/\(container)", isDirectory: true, password: password)
            let rootListing = try await provider.list(connection, path: "/", password: password)
            return ObjectStorageResult(
                listOK: listOK, downloadOK: downloadOK, renameOK: renameOK,
                missingObjectFailed: missingObjectFailed,
                invalidCredentialsFailed: invalidCredentialsFailed,
                cleanupOK: !rootListing.contains { $0.name == container })
        }
        let rootListing = try await provider.list(
            connection, path: "/\(container)", password: password)
        return ObjectStorageResult(
            listOK: listOK, downloadOK: downloadOK, renameOK: renameOK,
            missingObjectFailed: missingObjectFailed,
            invalidCredentialsFailed: invalidCredentialsFailed,
            cleanupOK: !rootListing.contains { $0.name == "docs" })
    }

    private static func runProcess(_ executable: String, _ arguments: [String]) -> (
        status: Int32, output: String
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        for key in [
            "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY",
            "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_COMMON_DIR", "GIT_PREFIX", "GIT_NAMESPACE",
        ] { environment.removeValue(forKey: key) }
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
#endif
