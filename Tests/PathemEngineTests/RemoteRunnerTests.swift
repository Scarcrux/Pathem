import Foundation
import Testing

@testable import PathemEngine

/// RemoteRunner drives every out-of-process backend (curl/sftp/adb/pathem-afc), so
/// its pipe draining and cancellation are load-bearing. These use real short-lived
/// /bin/sh processes rather than mocks (CONVENTIONS: prefer real I/O). The time
/// limit turns a regression into a failure instead of a hung suite.
@Suite(.timeLimit(.minutes(1))) struct RemoteRunnerTests {
    @Test func capturesStdoutStderrAndExitCode() async throws {
        let (out, code, err) = try await RemoteRunner.run(
            "/bin/sh", ["-c", "echo out; echo err 1>&2; exit 3"])
        #expect(String(decoding: out, as: UTF8.self).contains("out"))
        #expect(err.contains("err"))
        #expect(code == 3)
    }

    @Test func feedsStdinToTheChild() async throws {
        // `cat` echoes stdin back; confirms the input path still works end to end.
        let (out, code, _) = try await RemoteRunner.run("/bin/cat", [], input: "hello stdin")
        #expect(String(decoding: out, as: UTF8.self) == "hello stdin")
        #expect(code == 0)
    }

    @Test func finishesOnChildExitEvenWhenGrandchildHoldsStdout() async throws {
        // The shell backgrounds a `sleep` that inherits the stdout pipe's write end,
        // then exits immediately. A blocking readDataToEndOfFile would wait for the
        // grandchild to close the pipe (the sleep's full duration); we must instead
        // finish on the direct child's exit. This is the deadlock the audit flagged
        // (the real-world trigger is the persistent `adb` daemon).
        let started = Date()
        let (out, code, _) = try await RemoteRunner.run("/bin/sh", ["-c", "echo hello; sleep 5 &"])
        #expect(String(decoding: out, as: UTF8.self).contains("hello"))
        #expect(code == 0)
        #expect(Date().timeIntervalSince(started) < 3)  // not the 5s the grandchild lives
    }

    @Test func cancellationTerminatesPromptly() async throws {
        let started = Date()
        let task = Task { try await RemoteRunner.run("/bin/sh", ["-c", "sleep 30"]) }
        try await Task.sleep(nanoseconds: 300_000_000)  // let it start
        task.cancel()
        let (_, code, _) = try await task.value
        #expect(code != 0)  // terminated by signal, not a clean exit
        #expect(Date().timeIntervalSince(started) < 10)  // nowhere near the 30s sleep
    }
}
