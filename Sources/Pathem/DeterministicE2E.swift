#if DEBUG
import Foundation
import PathemEngine

/// Product-boundary checks for deterministic feature families that are otherwise covered only by
/// engine tests. These run inside the built Pathem executable, use real files and subprocesses, and
/// print the same RESULT contract as the other black-box scenarios.
enum DeterministicE2E {
    enum Suite: String {
        case files = "PATHEM_FILES_E2E"
        case archives = "PATHEM_ARCHIVES_E2E"
        case searchMetadata = "PATHEM_SEARCH_METADATA_E2E"
        case developerTools = "PATHEM_DEVELOPER_E2E"
        case remoteWebDAV = "PATHEM_WEBDAV_E2E"
    }

    static var requestedSuite: Suite? {
        let env = ProcessInfo.processInfo.environment
        return [Suite.files, .archives, .searchMetadata, .developerTools, .remoteWebDAV]
            .first { env[$0.rawValue] != nil }
    }

    @MainActor
    static func start(_ suite: Suite) {
        Task {
            var report = Report(title: suite.rawValue)
            do {
                switch suite {
                case .files: try runFiles(&report)
                case .archives: try await runArchives(&report)
                case .searchMetadata: try await runSearchMetadata(&report)
                case .developerTools: try await runDeveloperTools(&report)
                case .remoteWebDAV: try await runWebDAV(&report)
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
    }

    private static func runSearchMetadata(_ report: inout Report) async throws {
        let fm = FileManager.default
        let root = try workspace("search-metadata")
        defer { try? fm.removeItem(at: root) }
        let first = root.appendingPathComponent("first.txt")
        let second = root.appendingPathComponent("second.md")
        try "Needle one\nplain".write(to: first, atomically: true, encoding: .utf8)
        try "needle two\nneedle three".write(to: second, atomically: true, encoding: .utf8)

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
                && text(second) == "found two\nfound three")

        try FileTags.setTags([FileTag(name: "E2E", color: .blue)], on: first)
        report.check(
            "finder-tags-roundtrip",
            FileTags.tags(of: first) == [FileTag(name: "E2E", color: .blue)])
        try FileMetadata.setFinderComment("coverage-marker", on: first)
        report.check(
            "finder-comment-roundtrip",
            FileMetadata.finderComment(of: first) == "coverage-marker")
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
