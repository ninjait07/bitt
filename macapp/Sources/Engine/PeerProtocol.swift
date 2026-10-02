import Foundation

/// The BitTorrent peer wire protocol (BEP 3), plus BEP 10 / BEP 9 for magnets.
enum Wire {
    static let protocolName = Data("BitTorrent protocol".utf8)
    static let handshakeLength = 68
    static let metadataPieceSize = 16 * 1024
    /// Refuse absurd frames from hostile peers.
    static let maxMessageLength = 1 << 20

    enum MessageID: UInt8 {
        case choke = 0, unchoke = 1, interested = 2, notInterested = 3
        case have = 4, bitfield = 5, request = 6, piece = 7, cancel = 8, port = 9
        case extended = 20
    }

    /// Reserved-byte feature bits.
    static let extensionByte = 5
    static let extensionBit: UInt8 = 0x10

    /// ut_metadata sub-message types (BEP 9).
    enum MetadataMessage: Int {
        case request = 0, data = 1, reject = 2
    }

    enum WireError: LocalizedError {
        case notBitTorrent
        case badHandshakeLength(Int)
        case oversizedMessage(Int)
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .notBitTorrent: return "peer is not speaking BitTorrent"
            case .badHandshakeLength(let count):
                return "handshake must be \(handshakeLength) bytes, got \(count)"
            case .oversizedMessage(let length): return "peer announced a \(length)-byte message"
            case .malformed(let what): return "malformed \(what)"
            }
        }
    }

    // MARK: - Handshake

    static func makeHandshake(infoHash: Data, peerID: Data) -> Data {
        var reserved = [UInt8](repeating: 0, count: 8)
        reserved[extensionByte] |= extensionBit
        var out = Data([UInt8(protocolName.count)])
        out.append(protocolName)
        out.append(contentsOf: reserved)
        out.append(infoHash)
        out.append(peerID)
        return out
    }

    struct Handshake {
        let reserved: Data
        let infoHash: Data
        let peerID: Data
        var supportsExtensions: Bool {
            reserved.count > extensionByte
                && reserved[reserved.startIndex + extensionByte] & extensionBit != 0
        }
    }

    static func parseHandshake(_ data: Data) throws -> Handshake {
        guard data.count == handshakeLength else {
            throw WireError.badHandshakeLength(data.count)
        }
        let bytes = [UInt8](data)
        guard bytes[0] == 19, Data(bytes[1..<20]) == protocolName else {
            throw WireError.notBitTorrent
        }
        return Handshake(reserved: Data(bytes[20..<28]),
                         infoHash: Data(bytes[28..<48]),
                         peerID: Data(bytes[48..<68]))
    }

    // MARK: - Framing

    /// A framed message. `id` is nil for a keep-alive.
    static func frame(_ id: MessageID?, _ payload: Data = Data()) -> Data {
        guard let id else { return Data([0, 0, 0, 0]) }
        var out = Data()
        out.append(bigEndian: UInt32(payload.count + 1))
        out.append(id.rawValue)
        out.append(payload)
        return out
    }

    static func have(_ index: Int) -> Data {
        var payload = Data()
        payload.append(bigEndian: UInt32(index))
        return frame(.have, payload)
    }

    static func bitfield(_ bits: Data) -> Data { frame(.bitfield, bits) }

    static func request(index: Int, begin: Int, length: Int) -> Data {
        frame(.request, triple(index, begin, length))
    }

    static func cancel(index: Int, begin: Int, length: Int) -> Data {
        frame(.cancel, triple(index, begin, length))
    }

    static func piece(index: Int, begin: Int, block: Data) -> Data {
        var payload = Data()
        payload.append(bigEndian: UInt32(index))
        payload.append(bigEndian: UInt32(begin))
        payload.append(block)
        return frame(.piece, payload)
    }

    static func extended(_ extensionID: UInt8, _ payload: Data) -> Data {
        var body = Data([extensionID])
        body.append(payload)
        return frame(.extended, body)
    }

    private static func triple(_ a: Int, _ b: Int, _ c: Int) -> Data {
        var payload = Data()
        payload.append(bigEndian: UInt32(a))
        payload.append(bigEndian: UInt32(b))
        payload.append(bigEndian: UInt32(c))
        return payload
    }

    /// Which pieces a bitfield claims, ignoring the padding bits at the end.
    static func indices(inBitfield bits: Data, pieceCount: Int) -> [Int] {
        var out: [Int] = []
        for (byteIndex, byte) in bits.enumerated() where byte != 0 {
            for bit in 0..<8 where byte & (0x80 >> UInt8(bit)) != 0 {
                let index = byteIndex * 8 + bit
                if index < pieceCount { out.append(index) }
            }
        }
        return out
    }

    static func bitfieldBytes(have: [Bool]) -> Data {
        var out = Data(count: (have.count + 7) / 8)
        for (index, owned) in have.enumerated() where owned {
            out[index / 8] |= 0x80 >> UInt8(index % 8)
        }
        return out
    }

    // MARK: - BEP 10 / BEP 9

    static func extendedHandshake(metadataSize: Int?, clientVersion: String,
                                  listenPort: Int?) -> Data {
        var body: [Data: Bencode] = [
            Data(ascii: "m"): .dictionary([Data(ascii: "ut_metadata"): .integer(1)]),
            Data(ascii: "v"): .string(clientVersion),
            Data(ascii: "reqq"): .integer(250),
        ]
        if let metadataSize, metadataSize > 0 {
            body[Data(ascii: "metadata_size")] = .integer(metadataSize)
        }
        if let listenPort, listenPort > 0 {
            body[Data(ascii: "p")] = .integer(listenPort)
        }
        return extended(0, Bencode.dictionary(body).encoded())
    }

    static func metadataRequest(piece: Int) -> Data {
        Bencode.dictionary([
            Data(ascii: "msg_type"): .integer(MetadataMessage.request.rawValue),
            Data(ascii: "piece"): .integer(piece),
        ]).encoded()
    }

    static func metadataData(piece: Int, totalSize: Int, chunk: Data) -> Data {
        var out = Bencode.dictionary([
            Data(ascii: "msg_type"): .integer(MetadataMessage.data.rawValue),
            Data(ascii: "piece"): .integer(piece),
            Data(ascii: "total_size"): .integer(totalSize),
        ]).encoded()
        out.append(chunk)
        return out
    }

    static func metadataReject(piece: Int) -> Data {
        Bencode.dictionary([
            Data(ascii: "msg_type"): .integer(MetadataMessage.reject.rawValue),
            Data(ascii: "piece"): .integer(piece),
        ]).encoded()
    }

    /// Returns the header dictionary and whatever raw bytes follow it.
    static func parseMetadata(_ payload: Data) throws -> (header: Bencode, trailing: Data) {
        var index = payload.startIndex
        let header = try Bencode.decodePrefix(payload, from: &index)
        guard header.dictionaryValue != nil else {
            throw WireError.malformed("ut_metadata payload")
        }
        return (header, Data(payload[index...]))
    }

    // MARK: - Peer identity

    private static let clientCodes: [String: String] = [
        "AZ": "Azureus", "BT": "BitTorrent", "DE": "Deluge", "LT": "libtorrent",
        "lt": "libTorrent", "qB": "qBittorrent", "TR": "Transmission", "UT": "uTorrent",
        "UM": "uTorrent Mac", "BI": "BITT", "PY": "PyTorrent", "WW": "WebTorrent",
        "FD": "Free Download Mgr",
    ]

    /// Decode an Azureus-style peer id such as -qB4550-xxxxxxxxxxxx.
    static func clientName(peerID: Data?) -> String {
        guard let peerID, peerID.count >= 8,
              peerID[peerID.startIndex] == UInt8(ascii: "-") else { return "" }
        let bytes = [UInt8](peerID)
        let code = String(decoding: bytes[1..<3], as: UTF8.self)
        guard let name = clientCodes[code] else { return code }
        return "\(name) \(String(decoding: bytes[3..<7], as: UTF8.self))"
    }
}

// MARK: - Byte helpers

extension Data {
    mutating func append(bigEndian value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    /// Read a big-endian UInt32 at `offset` bytes from the start.
    func readUInt32(at offset: Int) -> UInt32? {
        guard count >= offset + 4 else { return nil }
        let start = index(startIndex, offsetBy: offset)
        return self[start..<index(start, offsetBy: 4)]
            .reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}
