import CryptoKit
import Foundation

enum MetainfoTests {
    /// Builds an info dictionary for `data` split into `pieceLength` pieces.
    static func syntheticInfo(data: Data, pieceLength: Int, name: String = "test.bin") -> Data {
        var hashes = Data()
        var offset = 0
        while offset < data.count {
            let end = min(offset + pieceLength, data.count)
            hashes.append(Data(Insecure.SHA1.hash(data: data[offset..<end])))
            offset = end
        }
        return Bencode.dictionary([
            Data(ascii: "name"): .string(name),
            Data(ascii: "piece length"): .integer(pieceLength),
            Data(ascii: "pieces"): .string(hashes),
            Data(ascii: "length"): .integer(data.count),
        ]).encoded()
    }

    static func run(fixtures: URL?) {
        Check.section("Metainfo")

        let payload = Data((0..<256_000).map { UInt8($0 % 251) })
        let info = syntheticInfo(data: payload, pieceLength: 32 * 1024)

        Check.that("piece sizes add up") {
            let meta = try Metainfo(rawInfo: info)
            let total = (0..<meta.pieceCount).reduce(0) { $0 + meta.pieceSize(at: $1) }
            return meta.pieceCount == 8 && total == 256_000
                && meta.pieceSize(at: 0) == 32 * 1024
                && meta.pieceSize(at: 7) == 256_000 - 7 * 32 * 1024
        }

        Check.that("info hash matches a direct SHA-1 of the info bytes") {
            let meta = try Metainfo(rawInfo: info)
            return meta.infoHash == Data(Insecure.SHA1.hash(data: info))
        }

        Check.throwsError("rejects a piece-count mismatch") {
            try Metainfo(rawInfo: Bencode.dictionary([
                Data(ascii: "name"): .string("x"),
                Data(ascii: "piece length"): .integer(16384),
                Data(ascii: "pieces"): .string(Data(count: 20)),
                Data(ascii: "length"): .integer(999_999),
            ]).encoded())
        }

        for bad in [1024, 1 << 30] {
            Check.throwsError("rejects a piece length of \(bad)") {
                try Metainfo(rawInfo: Bencode.dictionary([
                    Data(ascii: "name"): .string("x"),
                    Data(ascii: "piece length"): .integer(bad),
                    Data(ascii: "pieces"): .string(Data(count: 20)),
                    Data(ascii: "length"): .integer(bad),
                ]).encoded())
            }
        }

        Check.that("path traversal is neutralised") {
            let hostile = Bencode.dictionary([
                Data(ascii: "name"): .string(".."),
                Data(ascii: "piece length"): .integer(16384),
                Data(ascii: "pieces"): .string(Data(Insecure.SHA1.hash(data: Data([1])))),
                Data(ascii: "files"): .list([
                    .dictionary([
                        Data(ascii: "length"): .integer(1),
                        Data(ascii: "path"): .list([.string(".."), .string(".."),
                                                    .string("etc"), .string("passwd")]),
                    ])
                ]),
            ]).encoded()
            let meta = try Metainfo(rawInfo: hostile)
            return !meta.name.contains("..") && meta.files[0].path == "etc/passwd"
        }

        Check.section("Magnet links")

        Check.that("parses hex, name, trackers and peer hints") {
            let link = try MagnetLink(
                "magnet:?xt=urn:btih:c9e15763f722f23e98a29decdfae341b98d53056"
                + "&dn=Name+Here&tr=udp%3A%2F%2Ft.example%3A1337%2Fannounce&x.pe=1.2.3.4:6881")
            return link.infoHash.hexString == "c9e15763f722f23e98a29decdfae341b98d53056"
                && link.displayName == "Name Here"
                && link.trackers == ["udp://t.example:1337/announce"]
                && link.peers == ["1.2.3.4:6881"]
        }

        Check.that("accepts a base32 hash") {
            let hex = "c9e15763f722f23e98a29decdfae341b98d53056"
            let base32 = Data(hexString: hex)!.base32String
            return try MagnetLink("magnet:?xt=urn:btih:\(base32)").infoHash.hexString == hex
        }

        for bad in ["magnet:?dn=x", "magnet:?xt=urn:btmh:1220abcd", "http://example/x"] {
            Check.throwsError("rejects \(bad)") { try MagnetLink(bad) }
        }

        guard let fixtures else {
            print("  (skipping the cross-check against the Python engine: no fixtures)")
            return
        }
        crossCheck(fixtures: fixtures)
    }

    /// The real proof: parse a .torrent produced by the Python engine and make
    /// sure every derived value matches what Python computed.
    private static func crossCheck(fixtures: URL) {
        Check.section("Cross-check against the Python engine")

        let torrentURL = fixtures.appendingPathComponent("sample.torrent")
        let expectedURL = fixtures.appendingPathComponent("expected.json")

        guard let expectedData = try? Data(contentsOf: expectedURL),
              let expected = (try? JSONSerialization.jsonObject(with: expectedData))
                as? [String: Any] else {
            Check.that("fixtures are readable") { false }
            return
        }

        Check.that("parses the .torrent Python wrote") {
            _ = try Metainfo.parse(contentsOf: torrentURL)
            return true
        }

        guard let meta = try? Metainfo.parse(contentsOf: torrentURL) else { return }

        Check.equal("info hash", meta.infoHash.hexString, expected["info_hash"] as? String ?? "?")
        Check.equal("name", meta.name, expected["name"] as? String ?? "?")
        Check.equal("piece length", meta.pieceLength, expected["piece_length"] as? Int ?? -1)
        Check.equal("piece count", meta.pieceCount, expected["piece_count"] as? Int ?? -1)
        Check.equal("total length", meta.totalLength, expected["total_length"] as? Int ?? -1)
        Check.equal("trackers", meta.trackers, expected["trackers"] as? [String] ?? [])
        Check.equal("file paths", meta.files.map(\.path), expected["paths"] as? [String] ?? [])
        Check.equal("file offsets", meta.files.map(\.offset), expected["offsets"] as? [Int] ?? [])

        Check.that("every piece hash matches") {
            let hashes = (expected["piece_hashes"] as? [String]) ?? []
            return meta.pieceHashes.map(\.hexString) == hashes
        }

        Check.that("re-emitted .torrent keeps the same info hash") {
            let again = try Metainfo.parse(meta.torrentFileData())
            return again.infoHash == meta.infoHash && again.trackers == meta.trackers
        }
    }
}

extension Data {
    var base32String: String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0, accumulator = 0, out = ""
        for byte in self {
            accumulator = (accumulator << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[(accumulator >> bits) & 31])
            }
        }
        if bits > 0 { out.append(alphabet[(accumulator << (5 - bits)) & 31]) }
        return out
    }
}
