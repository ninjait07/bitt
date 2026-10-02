import Foundation

enum WireTests {
    static func run(fixtures: URL?) {
        Check.section("Peer wire protocol")

        let infoHash = Data(repeating: UInt8(ascii: "A"), count: 20)
        let peerID = Data("-PY0001-123456789012".utf8)

        Check.that("handshake round trip") {
            let raw = Wire.makeHandshake(infoHash: infoHash, peerID: peerID)
            let shake = try Wire.parseHandshake(raw)
            return raw.count == 68 && shake.supportsExtensions
                && shake.infoHash == infoHash && shake.peerID == peerID
        }

        Check.throwsError("rejects a non-BitTorrent handshake") {
            var raw = Wire.makeHandshake(infoHash: infoHash, peerID: peerID)
            raw[1] = UInt8(ascii: "X")
            return try Wire.parseHandshake(raw)
        }

        Check.equal("bitfield ignores padding bits",
                    Wire.indices(inBitfield: Data([0b1100_0000, 0b1111_1111]), pieceCount: 10),
                    [0, 1, 8, 9])

        Check.that("bitfield bytes round trip") {
            var have = [Bool](repeating: false, count: 20)
            [0, 3, 7, 8, 19].forEach { have[$0] = true }
            let bits = Wire.bitfieldBytes(have: have)
            return Wire.indices(inBitfield: bits, pieceCount: 20) == [0, 3, 7, 8, 19]
        }

        Check.that("ut_metadata data carries its trailing bytes") {
            let payload = Wire.metadataData(piece: 2, totalSize: 30_000, chunk: Data("xyz".utf8))
            let (header, trailing) = try Wire.parseMetadata(payload)
            return header["msg_type"]?.integerValue == Wire.MetadataMessage.data.rawValue
                && header["piece"]?.integerValue == 2
                && header["total_size"]?.integerValue == 30_000
                && trailing == Data("xyz".utf8)
        }

        for (id, expected) in [("-qB4550-abcdefghijkl", "qBittorrent 4550"),
                               ("-TR3000-abcdefghijkl", "Transmission 3000"),
                               ("M7-1-0--abcdefghijkl", "")] {
            Check.equal("client name for \(id)", Wire.clientName(peerID: Data(id.utf8)), expected)
        }

        guard let fixtures else { return }
        crossCheck(fixtures: fixtures, infoHash: infoHash, peerID: peerID)
    }

    /// Byte-for-byte comparison with the frames the Python engine emits. If these
    /// match, the Swift port speaks the same protocol as the implementation that
    /// already interoperates with qBittorrent, Transmission and Deluge.
    private static func crossCheck(fixtures: URL, infoHash: Data, peerID: Data) {
        Check.section("Wire bytes vs the Python engine")

        guard let data = try? Data(contentsOf: fixtures.appendingPathComponent("wire.json")),
              let expected = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else {
            Check.that("wire fixtures are readable") { false }
            return
        }

        func compare(_ name: String, _ produced: Data) {
            Check.equal(name, produced.hexString, expected[name] ?? "missing")
        }

        compare("handshake", Wire.makeHandshake(infoHash: infoHash, peerID: peerID))
        compare("keepalive", Wire.frame(nil))
        compare("choke", Wire.frame(.choke))
        compare("unchoke", Wire.frame(.unchoke))
        compare("interested", Wire.frame(.interested))
        compare("not_interested", Wire.frame(.notInterested))
        compare("have_5", Wire.have(5))
        compare("request", Wire.request(index: 1, begin: 0, length: 16384))
        compare("cancel", Wire.cancel(index: 7, begin: 32768, length: 16384))
        compare("piece", Wire.piece(index: 3, begin: 16384, block: Data("hello".utf8)))
        compare("bitfield", Wire.bitfield(Data([0xF0, 0x0F])))
        compare("metadata_request", Wire.metadataRequest(piece: 1))
        compare("metadata_reject", Wire.metadataReject(piece: 1))
        compare("metadata_data",
                Wire.metadataData(piece: 0, totalSize: 6961, chunk: Data("abc".utf8)))
        compare("extended_handshake",
                Wire.extendedHandshake(metadataSize: 6961,
                                       clientVersion: "pytorrent 1.0",
                                       listenPort: 6881))
    }
}
