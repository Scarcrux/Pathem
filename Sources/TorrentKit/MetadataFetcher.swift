import Foundation

#if canImport(Network)
    /// Fetches a torrent's metadata (the info dictionary) from a single peer using ut_metadata
    /// (BEP 9) over the extension protocol (BEP 10), so a magnet link can become a full download.
    /// One peer per call; the caller races several peers and keeps the first success.
    public enum MetadataFetcher {
        /// Connect to one peer and try to fetch + verify the metadata for `infoHash`. Returns a
        /// TorrentFile on success, or nil on any failure (bad peer, no extension support, timeout,
        /// hash mismatch).
        public static func fetch(
            host: String, port: UInt16, infoHash: Data, peerID: Data, trackers: [String],
            timeout: TimeInterval = 20
        ) async -> MetadataExchange.ResolvedTorrent? {
            let peer = PeerConnection(
                host: host, port: port, infoHash: infoHash, peerID: peerID, advertiseExtensions: true)
            defer { Task { await peer.close() } }

            do {
                try await peer.connect(timeout: timeout)
                guard await peer.peerSupportsExtensions else { return nil }
                try await peer.send(.extended(id: 0, payload: MetadataExchange.extendedHandshakePayload()))

                var peerMetadataID: UInt8?
                var metadataSize: Int?
                var blocks: [Int: Data] = [:]
                var expectedPieces: Int?
                var requested = false

                // Bound the exchange: metadata is small, so a handful of messages is plenty.
                for _ in 0..<256 {
                    let message = try await peer.receive(timeout: timeout)
                    guard case .extended(let extID, let payload) = message else { continue }

                    if extID == 0 {
                        let (id, size) = MetadataExchange.parseExtendedHandshake(payload)
                        peerMetadataID = id
                        metadataSize = size
                        if let id, let size, size > 0, !requested {
                            requested = true
                            expectedPieces = MetadataExchange.pieceCount(metadataSize: size)
                            for piece in 0..<expectedPieces! {
                                try await peer.send(.extended(id: id, payload: MetadataExchange.requestPayload(piece: piece)))
                            }
                        }
                    } else if let (piece, block) = MetadataExchange.parseDataMessage(payload) {
                        blocks[piece] = block
                        if let expectedPieces, blocks.count == expectedPieces {
                            var metadata = Data()
                            for i in 0..<expectedPieces { metadata.append(blocks[i] ?? Data()) }
                            if let size = metadataSize { metadata = metadata.prefix(size) }
                            return MetadataExchange.buildTorrent(
                                fromMetadata: metadata, infoHash: infoHash, trackers: trackers)
                        }
                    }
                    _ = peerMetadataID  // (kept for clarity; requests use the peer's id above)
                }
                return nil
            } catch {
                return nil
            }
        }
    }
#endif
