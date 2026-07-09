import Foundation

/// Peer exchange (BEP 11, ut_pex): connected peers periodically send us the peers they know about,
/// a cheap way to discover more peers without hitting trackers or the DHT. Rides on the BEP 10
/// extension protocol. We advertise support and parse the `added` peers others send; we don't yet
/// send our own PEX deltas (a good-citizen follow-up). Pure codec, unit-tested.
public enum PEX {
    /// The extension id we advertise for ut_pex (peers use it when sending us PEX messages).
    public static let utPexID = 2

    /// Our extended handshake advertising ut_pex support.
    public static func handshakePayload() -> Data {
        Bencode.dict([("m", .dict([("ut_pex", .int(Int64(utPexID)))]))]).encoded
    }

    /// The peer's ut_pex id from their extended handshake (needed only if we send them PEX).
    public static func peerPexID(fromHandshake payload: Data) -> UInt8? {
        guard let dict = try? BencodeDecoder.decode(payload) else { return nil }
        return dict["m"]?["ut_pex"]?.intValue.map { UInt8(truncatingIfNeeded: $0) }
    }

    /// Parse the `added` compact peers from a ut_pex message (ignoring flags and dropped peers).
    public static func parseAddedPeers(_ payload: Data) -> [Tracker.Peer] {
        guard let dict = try? BencodeDecoder.decode(payload), case .bytes(let added)? = dict["added"]
        else { return [] }
        return Tracker.parseCompactPeers(added)
    }
}
