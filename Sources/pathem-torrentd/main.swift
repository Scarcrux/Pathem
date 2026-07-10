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
            } else if let magnet = command.magnet {
                let save = command.savePath ?? defaultSavePath()
                if let status = await engine.addMagnet(uri: magnet, savePath: save) {
                    emit(.init(kind: .reply, replyTo: command.id, ok: true, message: status.name))
                } else {
                    emit(.init(kind: .reply, replyTo: command.id, ok: false,
                        message: "That doesn't look like a valid magnet link."))
                }
            } else {
                emit(.init(kind: .reply, replyTo: command.id, ok: false, message: "add needs a torrentPath or magnet"))
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
        let limits = await engine.currentLimits()
        emit(.init(kind: .reply, replyTo: command.id, ok: true, torrents: torrents,
            downLimit: limits.down, upLimit: limits.up, superSeed: limits.superSeed))
    case .setLimits:
        await engine.setLimits(
            down: command.downLimit ?? 0, up: command.upLimit ?? 0, superSeed: command.superSeed ?? false)
        let limits = await engine.currentLimits()
        emit(.init(kind: .reply, replyTo: command.id, ok: true,
            downLimit: limits.down, upLimit: limits.up, superSeed: limits.superSeed))
    case .files:
        guard let hash = command.infoHash else {
            emit(.init(kind: .reply, replyTo: command.id, ok: false, message: "files needs an infoHash"))
            return
        }
        let files = await engine.files(infoHash: hash)
        emit(.init(kind: .reply, replyTo: command.id, ok: true, infoHash: hash, files: files))
    case .setFiles:
        if let hash = command.infoHash {
            await engine.setFiles(infoHash: hash, wanted: command.wantedFiles)
        }
        emit(.init(kind: .reply, replyTo: command.id, ok: true))
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
        let limits = await engine.currentLimits()
        emit(.init(kind: .status, ok: true, torrents: torrents,
            downLimit: limits.down, upLimit: limits.up, superSeed: limits.superSeed))
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
