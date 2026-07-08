import Foundation
import Testing

@testable import PathemEngine

@Suite struct ExternalCommandTests {
    private let dir = URL(fileURLWithPath: "/tmp/pathem work")
    private var files: [URL] {
        [dir.appendingPathComponent("a b.txt"), dir.appendingPathComponent("c.txt")]
    }

    /// Thread-safe accumulator: runStreaming's onOutput fires from a background queue.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = ""
        func append(_ s: String) { lock.lock(); buffer += s; lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return buffer }
    }

    @Test func streamsCombinedOutputAndExitCode() {
        let collected = Collected()
        let exit = ExternalCommandRunner.runStreaming(
            .init(id: "t", name: "echo", command: "echo out; echo err 1>&2"),
            files: [], directory: FileManager.default.temporaryDirectory
        ) { collected.append($0) }
        #expect(exit == 0)
        #expect(collected.text.contains("out"))
        #expect(collected.text.contains("err"))  // stderr is merged into the same stream
    }

    @Test func streamingReportsNonZeroExit() {
        let collected = Collected()
        let exit = ExternalCommandRunner.runStreaming(
            .init(id: "t", name: "fail", command: "exit 3"),
            files: [], directory: FileManager.default.temporaryDirectory
        ) { collected.append($0) }
        #expect(exit == 3)
    }

    @Test func expandsPlaceholdersShellQuoted() {
        let out = ExternalCommandRunner.expand("tool %F in %D", files: files, directory: dir)
        #expect(out == "tool '/tmp/pathem work/a b.txt' '/tmp/pathem work/c.txt' in '/tmp/pathem work'")
    }

    @Test func expandsNamesAndParent() {
        #expect(ExternalCommandRunner.expand("%N", files: files, directory: dir) == "'a b.txt' 'c.txt'")
        #expect(ExternalCommandRunner.expand("%P", files: files, directory: dir) == "'/tmp/pathem work'")
    }

    @Test func doublePercentIsLiteral() {
        #expect(ExternalCommandRunner.expand("resize 50%% keep %%F", files: files, directory: dir)
            == "resize 50% keep %F")
    }

    @Test func quoteEscapesEmbeddedSingleQuote() {
        #expect(ExternalCommandRunner.shellQuote("it's") == "'it'\\''s'")
    }

    @Test func runsAndCapturesOutputAndExitCode() {
        let echo = ExternalCommand(id: "1", name: "echo", command: "echo hi %N")
        let out = ExternalCommandRunner.run(echo, files: files, directory: URL(fileURLWithPath: "/tmp"))
        #expect(out.succeeded)
        // The shell consumes the quotes we added, so echo sees "a b.txt" as one argument.
        #expect(out.text.trimmingCharacters(in: .whitespacesAndNewlines) == "hi a b.txt c.txt")

        let fail = ExternalCommand(id: "2", name: "false", command: "exit 3")
        #expect(ExternalCommandRunner.run(fail, files: [], directory: URL(fileURLWithPath: "/tmp")).exitCode == 3)
    }
}
