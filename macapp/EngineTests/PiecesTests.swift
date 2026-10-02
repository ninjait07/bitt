import Foundation

enum PiecesTests {
    static func run() {
        Check.section("Piece manager")

        let payload = Data((0..<200_000).map { UInt8(($0 &* 7) % 253) })
        let info = MetainfoTests.syntheticInfo(data: payload, pieceLength: 32 * 1024)
        guard let meta = try? Metainfo(rawInfo: info) else {
            Check.that("fixture metainfo builds") { false }
            return
        }

        func feed(_ manager: PieceManager, _ peer: Int, _ request: PieceManager.BlockRequest) {
            let start = request.index * meta.pieceLength + request.begin
            let slice = payload[start..<(start + request.length)]
            manager.blockReceived(from: peer, index: request.index,
                                  begin: request.begin, data: Data(slice))
        }

        Check.that("downloads every piece from one peer") {
            let manager = PieceManager(meta: meta)
            manager.addPeer(1)
            manager.peerHasBitfield(1, Array(0..<meta.pieceCount))
            var guard_ = 0
            while !manager.isComplete {
                guard let request = manager.nextRequest(for: 1) else { return false }
                feed(manager, 1, request)
                guard_ += 1
                if guard_ > 10_000 { return false }
            }
            return manager.downloadedBytes == payload.count && manager.hashFailures == 0
        }

        Check.that("bad data fails the hash and is offered again") {
            let manager = PieceManager(meta: meta)
            manager.addPeer(1)
            manager.peerHasBitfield(1, Array(0..<meta.pieceCount))
            guard let first = manager.nextRequest(for: 1) else { return false }
            manager.blockReceived(from: 1, index: first.index, begin: first.begin,
                                  data: Data(count: first.length))
            for _ in 1..<meta.blockCount(at: first.index) {
                guard let next = manager.nextRequest(for: 1) else { return false }
                manager.blockReceived(from: 1, index: next.index, begin: next.begin,
                                      data: Data(count: next.length))
            }
            return manager.hashFailures == 1 && !manager.have[first.index]
                && manager.nextRequest(for: 1) != nil
        }

        Check.that("picks the rarest piece first") {
            let manager = PieceManager(meta: meta)
            [1, 2, 3].forEach(manager.addPeer)
            manager.peerHasBitfield(1, Array(0..<meta.pieceCount))
            manager.peerHasBitfield(2, Array(0..<(meta.pieceCount - 1)))
            manager.peerHasBitfield(3, Array(0..<(meta.pieceCount - 1)))
            return manager.nextRequest(for: 1)?.index == meta.pieceCount - 1
        }

        Check.that("a dropped peer releases its requests and availability") {
            let manager = PieceManager(meta: meta)
            manager.addPeer(1)
            manager.peerHasBitfield(1, Array(0..<meta.pieceCount))
            guard let request = manager.nextRequest(for: 1) else { return false }
            manager.removePeer(1)
            guard manager.availability[request.index] == 0 else { return false }
            manager.addPeer(2)
            manager.peerHasBitfield(2, Array(0..<meta.pieceCount))
            return manager.nextRequest(for: 2) == request
        }

        Check.that("a peer with nothing we need is not useful") {
            let manager = PieceManager(meta: meta,
                                       have: [Bool](repeating: true, count: meta.pieceCount))
            manager.addPeer(1)
            manager.peerHasBitfield(1, [0, 1])
            return !manager.peerIsUseful(1) && manager.nextRequest(for: 1) == nil
        }

        Check.that("block sizes cover the short last piece exactly") {
            let manager = PieceManager(meta: meta)
            manager.addPeer(1)
            let last = meta.pieceCount - 1
            manager.peerHasBitfield(1, [last])
            var total = 0
            while let request = manager.nextRequest(for: 1) {
                guard request.length <= blockSize else { return false }
                total += request.length
                feed(manager, 1, request)
            }
            return total == meta.pieceSize(at: last)
        }

        Check.that("expired requests are offered again") {
            let manager = PieceManager(meta: meta)
            manager.addPeer(1)
            manager.peerHasBitfield(1, Array(0..<meta.pieceCount))
            guard let request = manager.nextRequest(for: 1) else { return false }
            manager.expireRequests(now: Date().timeIntervalSinceReferenceDate + 60)
            manager.addPeer(2)
            manager.peerHasBitfield(2, Array(0..<meta.pieceCount))
            return manager.nextRequest(for: 2) == request
        }
    }
}
