import Foundation
import Testing

@testable import PathemEngine

@Suite struct ProcessListTests {
    @Test func parsesPsOutput() {
        let out = """
              1     0 root         0.0  0.1  12345 /sbin/launchd
            842   1 alice        3.5  2.0 998877 /Applications/My App.app/Contents/MacOS/My App
            not a process line
            """
        let procs = ProcessList.parse(out)
        #expect(procs.count == 2)
        #expect(procs[0].pid == 1)
        #expect(procs[0].command == "/sbin/launchd")
        #expect(procs[0].name == "launchd")
        #expect(procs[1].pid == 842)
        #expect(procs[1].user == "alice")
        #expect(procs[1].cpu == 3.5)
        #expect(procs[1].rss == 998877)
        // command (and name) preserve spaces in the path.
        #expect(procs[1].command == "/Applications/My App.app/Contents/MacOS/My App")
        #expect(procs[1].name == "My App")
    }

    @Test func snapshotReturnsThisProcess() async {
        let procs = await ProcessList.snapshot()
        #expect(!procs.isEmpty)
        // Our own pid must be in the list.
        #expect(procs.contains { $0.pid == ProcessInfo.processInfo.processIdentifier })
    }
}
