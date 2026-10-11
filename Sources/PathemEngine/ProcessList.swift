import Foundation

/// One running process, as read from `ps`.
public struct RunningProcess: Sendable, Equatable, Identifiable {
    public let pid: Int32
    public let ppid: Int32
    public let user: String
    public let cpu: Double  // %CPU
    public let mem: Double  // %MEM
    public let rss: Int64  // resident size, KB
    public let command: String
    public var id: Int32 { pid }

    public init(
        pid: Int32, ppid: Int32, user: String, cpu: Double, mem: Double, rss: Int64, command: String
    ) {
        self.pid = pid
        self.ppid = ppid
        self.user = user
        self.cpu = cpu
        self.mem = mem
        self.rss = rss
        self.command = command
    }

    /// The executable's display name (last path component of the command).
    public var name: String { (command as NSString).lastPathComponent }
}

/// A snapshot of running processes, plus terminate, by shelling out to `ps`/`kill`
/// (out-of-process, like the rest of the engine). The parser is pure and tested.
public enum ProcessList {
    public static func snapshot() async -> [RunningProcess] {
        guard
            let (data, _, _) = try? await RemoteRunner.run(
                "/bin/ps", ["-axo", "pid=,ppid=,user=,%cpu=,%mem=,rss=,comm="])
        else { return [] }
        return parse(String(decoding: data, as: UTF8.self))
    }

    // Immutable compiled regex shared read-only. Preserve the older CI SDK fallback.
    #if compiler(>=6.4)
    private static let line = makeLinePattern()
    #else
    private nonisolated(unsafe) static let line = makeLinePattern()
    #endif

    private static func makeLinePattern() -> NSRegularExpression {
        try! NSRegularExpression(
            pattern: #"^\s*(\d+)\s+(\d+)\s+(\S+)\s+([0-9.]+)\s+([0-9.]+)\s+(\d+)\s+(.+?)\s*$"#)
    }

    static func parse(_ output: String) -> [RunningProcess] {
        var result: [RunningProcess] = []
        for raw in output.split(whereSeparator: \.isNewline) {
            let text = String(raw)
            let range = NSRange(text.startIndex..., in: text)
            guard let match = line.firstMatch(in: text, range: range) else { continue }
            func field(_ index: Int) -> String {
                guard let r = Range(match.range(at: index), in: text) else { return "" }
                return String(text[r])
            }
            guard let pid = Int32(field(1)), let ppid = Int32(field(2)) else { continue }
            result.append(
                RunningProcess(
                    pid: pid, ppid: ppid, user: field(3),
                    cpu: Double(field(4)) ?? 0, mem: Double(field(5)) ?? 0,
                    rss: Int64(field(6)) ?? 0, command: field(7)))
        }
        return result
    }

    /// Send SIGTERM (or SIGKILL when `force`) to a pid. Returns whether kill succeeded.
    public static func terminate(_ pid: Int32, force: Bool) async -> Bool {
        guard pid > 0,
            let (_, status, _) = try? await RemoteRunner.run(
                "/bin/kill", [force ? "-9" : "-15", "\(pid)"])
        else { return false }
        return status == 0
    }
}
