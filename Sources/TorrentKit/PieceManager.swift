import CryptoKit
import Foundation

/// Tracks which pieces and blocks of a torrent we hold, assembles incoming blocks, and verifies
/// each completed piece against its SHA-1 hash. Also picks the next block to request from a peer.
/// Pure bookkeeping over sizes and hashes; the socket and disk layers live elsewhere. Not
/// thread-safe on its own; the engine serializes access.
public final class PieceManager {
    /// 16 KiB is the near-universal block size peers accept for `request`.
    public static let blockSize = 16 * 1024

    public let pieceCount: Int
    public let pieceLength: Int
    public let totalLength: Int64
    private let pieceHashes: [Data]

    private var complete: [Bool]                 // verified pieces
    private var buffers: [Int: [UInt8]]          // piece index -> assembled bytes (in progress)
    private var received: [Int: Set<Int>]        // piece index -> block-begin offsets we hold

    public init(pieceCount: Int, pieceLength: Int, totalLength: Int64, pieceHashes: [Data]) {
        self.pieceCount = pieceCount
        self.pieceLength = pieceLength
        self.totalLength = totalLength
        self.pieceHashes = pieceHashes
        self.complete = Array(repeating: false, count: pieceCount)
        self.buffers = [:]
        self.received = [:]
    }

    public convenience init(torrent: TorrentFile) {
        self.init(
            pieceCount: torrent.pieceCount, pieceLength: Int(torrent.pieceLength),
            totalLength: torrent.totalLength, pieceHashes: torrent.pieceHashes)
    }

    // MARK: geometry

    /// The length of a piece in bytes; the last piece is usually short.
    public func pieceSize(_ index: Int) -> Int {
        guard index == pieceCount - 1 else { return pieceLength }
        let remainder = Int(totalLength % Int64(pieceLength))
        return remainder == 0 ? pieceLength : remainder
    }

    /// The number of blocks in a piece.
    public func blockCount(_ index: Int) -> Int {
        (pieceSize(index) + Self.blockSize - 1) / Self.blockSize
    }

    /// The length of the block at `begin` within a piece (the last block is usually short).
    public func blockLength(piece index: Int, begin: Int) -> Int {
        min(Self.blockSize, pieceSize(index) - begin)
    }

    // MARK: progress

    public func hasPiece(_ index: Int) -> Bool { index >= 0 && index < pieceCount && complete[index] }
    public var completedCount: Int { complete.lazy.filter { $0 }.count }
    public var isComplete: Bool { completedCount == pieceCount }

    /// Bytes verified so far (completed pieces only).
    public var downloadedBytes: Int64 {
        var total: Int64 = 0
        for i in 0..<pieceCount where complete[i] { total += Int64(pieceSize(i)) }
        return total
    }
    public var fractionComplete: Double {
        pieceCount == 0 ? 1 : Double(completedCount) / Double(pieceCount)
    }

    /// Our have-set as a bitfield (BEP 3): bit 0 is the high bit of byte 0.
    public func bitfield() -> Data {
        var bytes = [UInt8](repeating: 0, count: (pieceCount + 7) / 8)
        for i in 0..<pieceCount where complete[i] {
            bytes[i / 8] |= UInt8(0x80) >> (i % 8)
        }
        return Data(bytes)
    }

    /// Decode a peer's bitfield into a per-piece boolean array.
    public func decodeBitfield(_ data: Data) -> [Bool] {
        let bytes = [UInt8](data)
        return (0..<pieceCount).map { i in
            let byte = i / 8
            return byte < bytes.count && (bytes[byte] & (UInt8(0x80) >> (i % 8))) != 0
        }
    }

    // MARK: request selection

    public struct BlockRequest: Hashable, Sendable {
        public let index: Int
        public let begin: Int
        public let length: Int
    }

    /// Pick the next block to ask a peer for, given the pieces that peer advertises and the
    /// requests already in flight. Prefers finishing a piece already in progress before starting
    /// a new one (fewer half-done pieces on disconnect), otherwise takes the lowest-index piece
    /// the peer has. Returns nil when there is nothing left to ask this peer for.
    public func nextRequest(peerHas: [Bool], inFlight: Set<BlockRequest>) -> BlockRequest? {
        let started = buffers.keys.sorted()
        for index in started where index < peerHas.count && peerHas[index] && !complete[index] {
            if let req = firstNeededBlock(in: index, inFlight: inFlight) { return req }
        }
        for index in 0..<pieceCount where index < peerHas.count && peerHas[index] && !complete[index] {
            if let req = firstNeededBlock(in: index, inFlight: inFlight) { return req }
        }
        return nil
    }

    private func firstNeededBlock(in index: Int, inFlight: Set<BlockRequest>) -> BlockRequest? {
        let have = received[index] ?? []
        var begin = 0
        let size = pieceSize(index)
        while begin < size {
            let length = min(Self.blockSize, size - begin)
            let req = BlockRequest(index: index, begin: begin, length: length)
            if !have.contains(begin) && !inFlight.contains(req) { return req }
            begin += Self.blockSize
        }
        return nil
    }

    // MARK: ingest

    public enum BlockResult: Equatable {
        case accepted                        // stored; piece not complete yet
        case duplicate                       // already had this block
        case pieceComplete(index: Int, data: Data)  // piece finished and verified
        case hashMismatch(index: Int)        // piece finished but failed SHA-1; reset for retry
        case rejected                        // out of range or for a piece we already have
    }

    /// Store a received block. When a block completes its piece, the piece is SHA-1 verified: on
    /// success it is marked complete and its bytes returned for the caller to write to disk; on
    /// failure the piece is reset so it can be re-downloaded.
    public func receiveBlock(index: Int, begin: Int, block: Data) -> BlockResult {
        guard index >= 0, index < pieceCount, !complete[index] else { return .rejected }
        let size = pieceSize(index)
        guard begin >= 0, begin + block.count <= size, begin % Self.blockSize == 0 else { return .rejected }

        if received[index]?.contains(begin) == true { return .duplicate }

        var buffer = buffers[index] ?? [UInt8](repeating: 0, count: size)
        buffer.replaceSubrange(begin..<(begin + block.count), with: block)
        buffers[index] = buffer
        received[index, default: []].insert(begin)

        guard (received[index]?.count ?? 0) == blockCount(index) else { return .accepted }

        // The piece is fully assembled: verify it.
        let data = Data(buffer)
        let digest = Data(Insecure.SHA1.hash(data: data))
        buffers[index] = nil
        received[index] = nil
        if index < pieceHashes.count && digest == pieceHashes[index] {
            complete[index] = true
            return .pieceComplete(index: index, data: data)
        }
        return .hashMismatch(index: index)
    }

    /// Mark a piece complete without re-verifying (used when loading resume data from disk).
    public func markComplete(_ index: Int) {
        guard index >= 0, index < pieceCount else { return }
        complete[index] = true
        buffers[index] = nil
        received[index] = nil
    }
}
