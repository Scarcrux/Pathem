import Foundation
import TorrentKit

/// What a magnet still without its metadata is doing, in words. Shared by the Torrents drawer
/// and the Torrents window so both say the same thing. Nil when the torrent has its metadata.
enum TorrentStatusText {
    /// Whether the Pause/Resume control should resume: a paused torrent, or a magnet whose
    /// metadata search gave up (Resume starts a new search).
    static func resumes(_ status: TorrentSession.Status) -> Bool {
        status.state == .paused || status.metadataSearch?.phase == .gaveUp
    }

    static func metadataSearch(_ status: TorrentSession.Status) -> String? {
        guard let search = status.metadataSearch else { return nil }
        switch search.phase {
        case .fetchingSource:
            return L("torrents.meta.source", "Downloading the torrent file from its source…")
        case .findingPeers:
            return String(
                format: L("torrents.meta.finding", "Looking for peers (try %d of %d)…"),
                search.round, search.rounds)
        case .askingPeers:
            return String(
                format: L("torrents.meta.asking", "Asking %d peers for the file list…"),
                search.peersFound)
        case .waitingToRetry:
            return search.peersFound == 0
                ? String(
                    format: L(
                        "torrents.meta.retryNone", "No peers found yet (try %d of %d). Retrying…"),
                    search.round, search.rounds)
                : String(
                    format: L(
                        "torrents.meta.retrySome",
                        "%d peers found, none sent the file list (try %d of %d). Retrying…"),
                    search.peersFound, search.round, search.rounds)
        case .gaveUp:
            return String(
                format: L(
                    "torrents.meta.gaveUp",
                    "No peer sent the file list after %d tries. Resume to try again."),
                search.rounds)
        }
    }
}
