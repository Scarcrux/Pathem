import AVFoundation
import AVKit
import AppKit

/// Trim an audio or video file: load it into an AVPlayerView, show macOS's built-in trimming UI,
/// and export the chosen range to a new file with a passthrough (no re-encode) export session.
/// The "Trim" quick action for media, using only public AVKit/AVFoundation APIs.
@MainActor
final class TrimController: NSObject {
    /// File extensions AVFoundation can trim + export via passthrough.
    static let trimmableExtensions: Set<String> = ["mov", "mp4", "m4v", "m4a", "aac"]

    private var window: NSWindow?
    private let playerView = AVPlayerView()
    private var player: AVPlayer?
    private var sourceURL: URL?
    #if DEBUG
    private(set) var debugTransientTrimming = false
    #endif
    /// Called on the main thread with the new file after a successful export.
    var onExported: ((URL) -> Void)?
    var onFailed: ((String) -> Void)?

    /// Open `url` in a trimming window; the trim UI appears once the asset is ready.
    func trim(_ url: URL) {
        #if DEBUG
        debugTransientTrimming = false
        #endif
        sourceURL = url
        let player = AVPlayer(url: url)
        self.player = player
        playerView.player = player
        playerView.controlsStyle = .inline

        let window = self.window ?? makeWindow()
        self.window = window
        window.title = String(format: L("trim.title", "Trim “%@”"), url.lastPathComponent)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // The asset needs a beat to become trimmable; poll briefly, then begin (or report).
        beginWhenReady(attempts: 0)
    }

    private func beginWhenReady(attempts: Int) {
        if playerView.canBeginTrimming {
            #if DEBUG
            debugTransientTrimming = true
            #endif
            playerView.beginTrimming { [weak self] result in
                let accepted = result == .okButton
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if accepted {
                        self.export()
                    } else {
                        self.window?.orderOut(nil)
                    }
                }
            }
        } else if attempts < 20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.beginWhenReady(attempts: attempts + 1)
            }
        } else {
            window?.orderOut(nil)
            onFailed?(L("trim.cantTrim", "This file can’t be trimmed."))
        }
    }

    private func export() {
        guard let url = sourceURL, let item = player?.currentItem else { return }
        let start = item.reversePlaybackEndTime  // the trim UI records the range on the player item
        let end = item.forwardPlaybackEndTime
        guard CMTIME_IS_VALID(start), CMTIME_IS_VALID(end), start < end else {
            finishFailure(L("trim.noRange", "No trim range was selected."))
            return
        }
        let asset = AVURLAsset(url: url)
        guard
            let session = AVAssetExportSession(
                asset: asset, presetName: AVAssetExportPresetPassthrough)
        else {
            finishFailure(L("trim.noExport", "Couldn’t prepare the export."))
            return
        }
        let output = Self.uniqueOutput(for: url)
        let type = Self.fileType(for: url, supported: session.supportedFileTypes)
        session.timeRange = CMTimeRange(start: start, end: end)
        // The package minimum is macOS 15. Use its throwing async export instead of
        // reading non-Sendable session/status/error from a completion queue.
        Task { @MainActor [weak self] in
            do {
                try await session.export(to: output, as: type)
                self?.window?.orderOut(nil)
                self?.onExported?(output)
            } catch {
                let message = error.localizedDescription
                self?.finishFailure(
                    message.isEmpty ? L("trim.exportFailed", "The export failed.") : message)
            }
        }
    }

    private func finishFailure(_ message: String) {
        window?.orderOut(nil)
        onFailed?(message)
    }

    /// "<name> trimmed.<ext>", made unique in the source folder.
    private static func uniqueOutput(for url: URL) -> URL {
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent + " trimmed"
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    /// Prefer the file type matching the source's extension; otherwise the first the session supports.
    private static func fileType(for url: URL, supported: [AVFileType]) -> AVFileType {
        let byExtension: [String: AVFileType] = [
            "mov": .mov, "mp4": .mp4, "m4v": .m4v, "m4a": .m4a, "aac": .m4a,
        ]
        if let wanted = byExtension[url.pathExtension.lowercased()], supported.contains(wanted) {
            return wanted
        }
        return supported.first ?? .mov
    }

    /// Export a time range from `url` without the interactive UI (PATHEM_TRIM_SMOKE): exercises the
    /// same passthrough export the trim UI uses. Returns the output URL, or nil on failure.
    static func debugExport(from url: URL, startSeconds: Double, endSeconds: Double) async -> URL? {
        let asset = AVURLAsset(url: url)
        guard
            let session = AVAssetExportSession(
                asset: asset, presetName: AVAssetExportPresetPassthrough)
        else { return nil }
        let output = uniqueOutput(for: url)
        let type = fileType(for: url, supported: session.supportedFileTypes)
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: startSeconds, preferredTimescale: 600),
            end: CMTime(seconds: endSeconds, preferredTimescale: 600))
        do {
            try await session.export(to: output, as: type)
            return output
        } catch { return nil }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false  // cached in self.window; the default extra release UAFs
        window.center()
        playerView.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(playerView)
        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: content.topAnchor),
            playerView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        return window
    }
}
