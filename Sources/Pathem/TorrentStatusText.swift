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
            return L("torrents.meta.source", "Fetching the torrent file…")
        case .findingPeers:
            return String(
                format: L("torrents.meta.finding", "Finding peers (try %d of %d)…"),
                search.round, search.rounds)
        case .askingPeers:
            return String(
                format: L("torrents.meta.asking", "Asking %d peers for the file list…"),
                search.peersFound)
        case .waitingToRetry:
            return search.peersFound == 0
                ? String(
                    format: L(
                        "torrents.meta.retryNone", "No peers yet. Retrying (%d of %d)…"),
                    search.round, search.rounds)
                : String(
                    format: L(
                        "torrents.meta.retrySome",
                        "%d peers, no file list. Retrying (%d of %d)…"),
                    search.peersFound, search.round, search.rounds)
        case .gaveUp:
            return String(
                format: L(
                    "torrents.meta.gaveUp",
                    "No file list after %d tries. Resume to retry."),
                search.rounds)
        }
    }
}
