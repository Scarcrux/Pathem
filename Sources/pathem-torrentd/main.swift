import Foundation
import TorrentKit

// pathem-torrentd: the long-running torrent daemon. The Pathem app spawns this process and talks
// to it over a line-delimited JSON control protocol -- one Command per line on stdin, one Event
// per line on stdout. It owns a TorrentEngine, restores persisted torrents on launch, and
// broadcasts a status snapshot roughly once a second so the Torrents panel stays live.
//
// State lives under the directory given as argv[1] (the app passes its Application Support path);
// it falls back to ~/Library/Application Support/Pathem/Torrents.

let stateDir: URL = {
    if CommandLine.arguments.count > 1 {
        return URL(fileURLWithPath: CommandLine.arguments[1])
    }
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("Pathem/Torrents")
}()
try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

let engine = TorrentEngine(stateDir: stateDir)
let out = FileHandle.standardOutput
let writeLock = NSLock()

func emit(_ event: TorrentControl.Event) {
    writeLock.lock()
    out.write(TorrentControl.encodeLine(event))
    writeLock.unlock()
}

/// Run one command and reply.
func handle(_ command: TorrentControl.Command) async {
    switch command.op {
    case .add:
        do {
            if let path = command.torrentPath {
                let save = command.savePath ?? defaultSavePath()
                let status = try await engine.addTorrentFile(at: path, savePath: save)
                emit(.init(kind: .reply, replyTo: command.id, ok: true, message: status.name))
            } else if command.magnet != nil {
                // Magnet support needs BEP 9 metadata exchange, which isn't built yet.
                emit(.init(kind: .reply, replyTo: command.id, ok: false,
                    message: "Magnet links need metadata exchange, which isn't available yet. Add a .torrent file."))
            } else {
                emit(.init(kind: .reply, replyTo: command.id, ok: false, message: "add needs a torrentPath"))
            }
        } catch {
            emit(.init(kind: .reply, replyTo: command.id, ok: false, message: "\(error)"))
        }
    case .remove:
        if let hash = command.infoHash { await engine.remove(infoHash: hash, deleteData: false) }
        emit(.init(kind: .reply, replyTo: command.id, ok: true))
    case .removeData:
        if let hash = command.infoHash { await engine.remove(infoHash: hash, deleteData: true) }
        emit(.init(kind: .reply, replyTo: command.id, ok: true))
    case .pause:
        if let hash = command.infoHash { await engine.pause(infoHash: hash) }
        emit(.init(kind: .reply, replyTo: command.id, ok: true))
    case .resume:
        if let hash = command.infoHash { await engine.resume(infoHash: hash) }
        emit(.init(kind: .reply, replyTo: command.id, ok: true))
    case .list:
        let torrents = await engine.statuses()
        emit(.init(kind: .reply, replyTo: command.id, ok: true, torrents: torrents))
    }
}

func defaultSavePath() -> String {
    FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
        ?? NSHomeDirectory() + "/Downloads"
}

// Broadcast status + checkpoint resume data on a timer.
let ticker = Task {
    while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let torrents = await engine.statuses()
        emit(.init(kind: .status, ok: true, torrents: torrents))
        await engine.checkpoint()
    }
}

// Restore persisted torrents, then announce readiness.
Task {
    await engine.restoreAll()
    emit(.init(kind: .status, ok: true, message: "ready", torrents: await engine.statuses()))
}

// Read commands on a dedicated thread. `readLine` is a blocking syscall; running it inside a
// Task would park a cooperative-pool thread and starve the async ticker, so it lives on its own
// Thread and hands each decoded command to the async world.
let reader = Thread {
    while let line = readLine(strippingNewline: true) {
        guard !line.isEmpty, let data = line.data(using: .utf8),
            let command = try? JSONDecoder().decode(TorrentControl.Command.self, from: data)
        else { continue }
        Task { await handle(command) }
    }
    // stdin closed (the app quit): persist and exit.
    Task {
        await engine.checkpoint()
        ticker.cancel()
        exit(0)
    }
}
reader.stackSize = 1 << 20
reader.start()

RunLoop.main.run()
