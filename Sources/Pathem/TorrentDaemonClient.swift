import Foundation
import TorrentKit

/// The app-side driver for the out-of-process torrent daemon (`pathem-torrentd`). Spawns the
/// helper on first use, sends commands as line-delimited JSON on its stdin, and reads the status
/// events it streams back on stdout. Keeping the peer/network code in a separate process matches
/// Pathem's model of not running risky network parsing inside the Full-Disk-Access app.
///
/// One shared instance per app; the daemon stays alive while the app runs and its downloads
/// persist across restarts (the daemon checkpoints resume data itself).
@MainActor
final class TorrentDaemonClient {
    static let shared = TorrentDaemonClient()

    /// Latest snapshot of every torrent, and a callback fired whenever it changes.
    private(set) var torrents: [TorrentSession.Status] = []
    var onUpdate: (([TorrentSession.Status]) -> Void)?
    var onError: ((String) -> Void)?

    private var process: Process?
    private var stdin: FileHandle?
    private var inbound = Data()
    private var nextID = 1
    private var streamTask: Task<Void, Never>?
    private var continuation: AsyncStream<Data>.Continuation?

    private init() {}

    var isRunning: Bool { process?.isRunning == true }

    // MARK: lifecycle

    /// Launch the daemon if it isn't already running. Safe to call repeatedly.
    @discardableResult
    func startIfNeeded() -> Bool {
        if isRunning { return true }
        guard let path = Self.helperPath(), let stateDir = ConfigStore.directory() else { return false }
        let torrentsState = stateDir.appendingPathComponent("Torrents", isDirectory: true)
        try? FileManager.default.createDirectory(at: torrentsState, withIntermediateDirectories: true)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = [torrentsState.path]

        let inPipe = Pipe()
        let outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        if let debugErr = ProcessInfo.processInfo.environment["PATHEM_TORRENTD_STDERR"] {
            FileManager.default.createFile(atPath: debugErr, contents: nil)
            proc.standardError = FileHandle(forWritingAtPath: debugErr) ?? FileHandle.nullDevice
        } else {
            proc.standardError = FileHandle.nullDevice
        }

        // Chunks from the pipe's serial queue are yielded into an AsyncStream and drained by a
        // single ordered consumer on the main actor. Hopping per-chunk with detached tasks would
        // reorder the bytes and corrupt the newline framing, so all buffering happens here in
        // arrival order.
        let (stream, cont) = AsyncStream<Data>.makeStream()
        continuation = cont
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                cont.finish()
                return
            }
            cont.yield(data)
        }
        streamTask = Task { [weak self] in
            for await chunk in stream {
                self?.ingest(chunk)
            }
        }
        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.handleTermination() }
        }

        do {
            try proc.run()
        } catch {
            return false
        }
        process = proc
        stdin = inPipe.fileHandleForWriting
        return true
    }

    /// Close the daemon's stdin, which makes it checkpoint and exit cleanly.
    func shutdown() {
        try? stdin?.close()
        stdin = nil
        process = nil
        continuation?.finish()
        continuation = nil
        streamTask?.cancel()
        streamTask = nil
    }

    private func handleTermination() {
        process = nil
        stdin = nil
        inbound.removeAll()
        continuation?.finish()
        continuation = nil
        streamTask?.cancel()
        streamTask = nil
    }

    // MARK: commands

    func addTorrent(fileAt path: String, savePath: String?) {
        send(.init(op: .add, id: nextCommandID(), torrentPath: path, savePath: savePath))
    }

    func addMagnet(_ uri: String, savePath: String?) {
        send(.init(op: .add, id: nextCommandID(), magnet: uri, savePath: savePath))
    }

    func pause(_ infoHash: String) { send(.init(op: .pause, id: nextCommandID(), infoHash: infoHash)) }
    func resume(_ infoHash: String) { send(.init(op: .resume, id: nextCommandID(), infoHash: infoHash)) }

    func remove(_ infoHash: String, deleteData: Bool) {
        send(.init(op: deleteData ? .removeData : .remove, id: nextCommandID(), infoHash: infoHash))
    }

    func requestList() { send(.init(op: .list, id: nextCommandID())) }

    private func send(_ command: TorrentControl.Command) {
        guard startIfNeeded(), let stdin else { return }
        // SIGPIPE is ignored process-wide; a write to a dead daemon fails harmlessly.
        try? stdin.write(contentsOf: TorrentControl.encodeLine(command))
    }

    private func nextCommandID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    // MARK: stdout stream

    private func ingest(_ data: Data) {
        inbound.append(data)
        while let newline = inbound.firstIndex(of: 0x0a) {
            let line = inbound[inbound.startIndex..<newline]
            inbound.removeSubrange(inbound.startIndex...newline)
            guard !line.isEmpty,
                let event = try? JSONDecoder().decode(TorrentControl.Event.self, from: Data(line))
            else { continue }
            handle(event)
        }
    }

    private func handle(_ event: TorrentControl.Event) {
        if let torrents = event.torrents {
            self.torrents = torrents
            onUpdate?(torrents)
        }
        if !event.ok, let message = event.message, event.kind == .reply {
            onError?(message)
        }
    }

    // MARK: helper location

    /// Locate the bundled daemon (next to the app executable) or the dev build product.
    static func helperPath() -> String? {
        var candidates: [String] = []
        if let exe = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(exe.appendingPathComponent("pathem-torrentd").path)
        }
        candidates.append(
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
                .appendingPathComponent("pathem-torrentd").path)
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
