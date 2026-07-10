import Foundation

/// Super-seeding piece selection (the "super seed" / initial-seeding mode). Instead of advertising
/// everything, a super-seed offers each peer one piece at a time, preferring pieces it has handed
/// out least, so a fresh swarm spreads distinct pieces around before any peer re-shares. Pure
/// selection logic; the session drives the per-peer state machine.
public enum SuperSeed {
    /// Pick the next piece to offer a peer: one we have, the peer lacks, we haven't already offered
    /// it, chosen to minimize how many times we've handed that piece out. Nil if there's nothing
    /// useful to offer.
    public static func pick(
        complete: [Bool], peerHas: [Bool], offered: Set<Int>, givenCount: [Int: Int]
    ) -> Int? {
        var best: Int?
        var bestCount = Int.max
        for index in 0..<complete.count {
            guard complete[index], !offered.contains(index) else { continue }
            if index < peerHas.count && peerHas[index] { continue }  // peer already has it
            let count = givenCount[index, default: 0]
            if count < bestCount {
                bestCount = count
                best = index
            }
        }
        return best
    }
}
