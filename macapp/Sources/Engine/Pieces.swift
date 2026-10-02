import CryptoKit
import Foundation

/// Piece picking and block bookkeeping.
///
/// Strategy: rarest-first across the swarm with a random tie-break, so peers do
/// not all converge on the same piece, then endgame duplication once the tail is
/// in sight.
final class PieceManager {
    struct BlockRequest: Equatable {
        let index: Int
        let begin: Int
        let length: Int
    }

    /// Seconds before an unanswered block is offered to someone else.
    static let requestTimeout: TimeInterval = 30
    /// Start duplicating requests inside this many pieces.
    static let endgamePieces = 4

    private enum BlockState { case pending, requested, done }

    private final class Block {
        let begin: Int
        let length: Int
        var state: BlockState = .pending
        var requestedAt: TimeInterval = 0
        var peers: Set<Int> = []
        init(begin: Int, length: Int) { self.begin = begin; self.length = length }
    }

    private final class Piece {
        let index: Int
        let size: Int
        var blocks: [Block]
        var buffer: Data
        var received = 0

        init(index: Int, size: Int) {
            self.index = index
            self.size = size
            self.buffer = Data(count: size)
            var blocks: [Block] = []
            var begin = 0
            while begin < size {
                let length = min(blockSize, size - begin)
                blocks.append(Block(begin: begin, length: length))
                begin += length
            }
            self.blocks = blocks
        }

        var isComplete: Bool { received == size }
    }

    let meta: Metainfo
    private(set) var have: [Bool]
    private(set) var availability: [Int]
    private(set) var bytesVerified: Int
    private(set) var hashFailures = 0

    private var active: [Int: Piece] = [:]
    private var peerPieces: [Int: Set<Int>] = [:]

    init(meta: Metainfo, have: [Bool]? = nil) {
        self.meta = meta
        self.have = have ?? [Bool](repeating: false, count: meta.pieceCount)
        self.availability = [Int](repeating: 0, count: meta.pieceCount)
        self.bytesVerified = self.have.enumerated()
            .reduce(0) { $1.element ? $0 + meta.pieceSize(at: $1.offset) : $0 }
    }

    // MARK: - Swarm bookkeeping

    func addPeer(_ key: Int) {
        if peerPieces[key] == nil { peerPieces[key] = [] }
    }

    func removePeer(_ key: Int) {
        for index in peerPieces.removeValue(forKey: key) ?? [] where availability[index] > 0 {
            availability[index] -= 1
        }
        releaseRequests(of: key)
    }

    func peerHasPiece(_ key: Int, _ index: Int) {
        guard index >= 0, index < meta.pieceCount else { return }
        if peerPieces[key] == nil { peerPieces[key] = [] }
        if peerPieces[key]!.insert(index).inserted {
            availability[index] += 1
        }
    }

    func peerHasBitfield(_ key: Int, _ indices: [Int]) {
        indices.forEach { peerHasPiece(key, $0) }
    }

    func pieces(of key: Int) -> Set<Int> { peerPieces[key] ?? [] }

    /// Does this peer hold anything we still need?
    func peerIsUseful(_ key: Int) -> Bool {
        (peerPieces[key] ?? []).contains { !have[$0] }
    }

    // MARK: - Progress

    var isComplete: Bool { !have.contains(false) }
    var piecesDone: Int { have.lazy.filter { $0 }.count }
    var missingPieces: Int { meta.pieceCount - piecesDone }

    /// Verified bytes plus whatever is buffered in partial pieces.
    var downloadedBytes: Int {
        bytesVerified + active.values.reduce(0) { $0 + $1.received }
    }

    func bitfieldData() -> Data { Wire.bitfieldBytes(have: have) }

    // MARK: - Picking

    func expireRequests(now: TimeInterval = Date().timeIntervalSinceReferenceDate) {
        for piece in active.values {
            for block in piece.blocks
            where block.state == .requested && now - block.requestedAt > Self.requestTimeout {
                block.state = .pending
                block.peers.removeAll()
            }
        }
    }

    /// Hand back everything this peer had outstanding.
    func releaseRequests(of key: Int) {
        for piece in active.values {
            for block in piece.blocks where block.peers.contains(key) {
                block.peers.remove(key)
                if block.state == .requested && block.peers.isEmpty {
                    block.state = .pending
                }
            }
        }
    }

    /// Pick the next block to ask this peer for.
    func nextRequest(for key: Int) -> BlockRequest? {
        guard let owned = peerPieces[key], !owned.isEmpty else { return nil }

        // Finish pieces already in flight before opening new ones.
        for index in active.keys.sorted(by: { (active[$0]?.received ?? 0) > (active[$1]?.received ?? 0) })
        where owned.contains(index) && !have[index] {
            if let request = take(from: active[index]!, by: key) { return request }
        }

        if let index = chooseNewPiece(owned: owned) {
            let piece = Piece(index: index, size: meta.pieceSize(at: index))
            active[index] = piece
            if let request = take(from: piece, by: key) { return request }
        }

        return endgameRequest(for: key, owned: owned)
    }

    private func take(from piece: Piece, by key: Int) -> BlockRequest? {
        guard let block = piece.blocks.first(where: { $0.state == .pending }) else { return nil }
        block.state = .requested
        block.requestedAt = Date().timeIntervalSinceReferenceDate
        block.peers.insert(key)
        return BlockRequest(index: piece.index, begin: block.begin, length: block.length)
    }

    private func chooseNewPiece(owned: Set<Int>) -> Int? {
        var rarest: Int?
        var candidates: [Int] = []
        for index in owned where !have[index] && active[index] == nil {
            let rarity = availability[index]
            if rarest == nil || rarity < rarest! {
                rarest = rarity
                candidates = [index]
            } else if rarity == rarest! {
                candidates.append(index)
            }
        }
        return candidates.randomElement()
    }

    /// Near the end, re-ask other peers for blocks that are still in flight.
    private func endgameRequest(for key: Int, owned: Set<Int>) -> BlockRequest? {
        guard missingPieces <= Self.endgamePieces else { return nil }
        for (index, piece) in active where owned.contains(index) && !have[index] {
            for block in piece.blocks
            where block.state == .requested && !block.peers.contains(key) {
                block.peers.insert(key)
                return BlockRequest(index: index, begin: block.begin, length: block.length)
            }
        }
        return nil
    }

    // MARK: - Receiving

    /// Record a block.
    ///
    /// `pieceData` is non-nil only when the piece just completed *and* its SHA-1
    /// matched, so the caller can write it straight to disk.
    @discardableResult
    func blockReceived(from key: Int, index: Int, begin: Int, data: Data)
        -> (completed: Bool, pieceData: Data?) {
        guard let piece = active[index], !have[index] else { return (false, nil) }
        let position = begin / blockSize
        guard position < piece.blocks.count else { return (false, nil) }
        let block = piece.blocks[position]
        guard block.begin == begin, block.state != .done, data.count == block.length else {
            return (false, nil)
        }

        piece.buffer.replaceSubrange(
            piece.buffer.index(piece.buffer.startIndex, offsetBy: begin)
            ..< piece.buffer.index(piece.buffer.startIndex, offsetBy: begin + data.count),
            with: data)
        block.state = .done
        block.peers.removeAll()
        piece.received += data.count

        guard piece.isComplete else { return (false, nil) }

        active.removeValue(forKey: index)
        let complete = piece.buffer
        guard Data(Insecure.SHA1.hash(data: complete)) == meta.pieceHashes[index] else {
            hashFailures += 1
            return (true, nil)   // completed, but corrupt: it gets picked again
        }

        have[index] = true
        bytesVerified += piece.size
        return (true, complete)
    }

    func markHave(_ index: Int) {
        if !have[index] {
            have[index] = true
            bytesVerified += meta.pieceSize(at: index)
        }
        active.removeValue(forKey: index)
    }

    /// Used when a write fails and the piece has to be fetched again.
    func markMissing(_ index: Int) {
        if have[index] {
            have[index] = false
            bytesVerified -= meta.pieceSize(at: index)
        }
    }
}
