import CryptoKit
import Foundation

let blockSize = 16 * 1024
private let maxPieceLength = 64 * 1024 * 1024      // a piece is buffered in memory while it downloads
private let maxPieceCount = 4_000_000              // guards against a hostile 'pieces' string
private let maxTotalLength = 1 << 50               // 1 PiB

enum MetainfoError: LocalizedError {
    case notATorrent(String)
    case badPieceLength(Int)
    case badPieces
    case tooManyPieces(Int)
    case pieceCountMismatch(hashes: Int, bytes: Int, pieceLength: Int)
    case missingLength
    case malformedFiles
    case implausiblySized
    case notAMagnet
    case unusableMagnet
    case versionTwoMagnet

    var errorDescription: String? {
        switch self {
        case .notATorrent(let why): return "not a valid .torrent file: \(why)"
        case .badPieceLength(let value):
            return "'piece length' of \(value) is outside the usable range (\(blockSize)…\(maxPieceLength))"
        case .badPieces: return "missing or malformed 'pieces'"
        case .tooManyPieces(let count): return "torrent declares \(count) pieces"
        case .pieceCountMismatch(let hashes, let bytes, let pieceLength):
            return "piece count mismatch: \(hashes) hashes for \(bytes) bytes of \(pieceLength)-byte pieces"
        case .missingLength: return "single-file torrent without 'length'"
        case .malformedFiles: return "malformed 'files' list"
        case .implausiblySized: return "torrent is implausibly large"
        case .notAMagnet: return "not a magnet link"
        case .unusableMagnet: return "magnet link has no usable btih info-hash"
        case .versionTwoMagnet: return "BitTorrent v2 magnet links (btmh) are not supported"
        }
    }
}

/// One file in the torrent, placed at [offset, offset+length) of the stream.
struct FileEntry: Equatable {
    let path: String        // relative, already sanitised
    let length: Int
    let offset: Int
}

/// A fully known torrent: the `info` dictionary plus where it came from.
struct Metainfo {
    let rawInfo: Data
    let infoHash: Data
    let pieceLength: Int
    let pieceHashes: [Data]
    let name: String
    let files: [FileEntry]
    let totalLength: Int
    let isPrivate: Bool
    let isMultiFile: Bool
    var trackers: [String]

    var pieceCount: Int { pieceHashes.count }

    func pieceSize(at index: Int) -> Int {
        precondition(index >= 0 && index < pieceCount)
        guard index == pieceCount - 1 else { return pieceLength }
        let remainder = totalLength - pieceLength * index
        return remainder > 0 ? remainder : pieceLength
    }

    func blockCount(at index: Int) -> Int {
        (pieceSize(at: index) + blockSize - 1) / blockSize
    }

    // MARK: - Building

    init(rawInfo: Data, trackers: [String] = []) throws {
        let value = try Bencode.decode(rawInfo)
        guard value.dictionaryValue != nil else {
            throw MetainfoError.notATorrent("info is not a dictionary")
        }
        self.rawInfo = rawInfo
        self.infoHash = Data(Insecure.SHA1.hash(data: rawInfo))
        self.trackers = trackers

        let declaredLength = value["piece length"]?.integerValue ?? 0
        guard declaredLength >= blockSize, declaredLength <= maxPieceLength else {
            throw MetainfoError.badPieceLength(declaredLength)
        }
        pieceLength = declaredLength

        guard let pieces = value["pieces"]?.dataValue,
              !pieces.isEmpty, pieces.count % 20 == 0 else {
            throw MetainfoError.badPieces
        }
        guard pieces.count / 20 <= maxPieceCount else {
            throw MetainfoError.tooManyPieces(pieces.count / 20)
        }
        pieceHashes = stride(from: 0, to: pieces.count, by: 20).map {
            Data(pieces[pieces.index(pieces.startIndex, offsetBy: $0)
                        ..< pieces.index(pieces.startIndex, offsetBy: $0 + 20)])
        }

        name = Metainfo.safeComponent(value["name"]?.dataValue) ?? infoHash.hexString
        isPrivate = (value["private"]?.integerValue ?? 0) != 0

        let (entries, total, multi) = try Metainfo.parseFiles(info: value, name: name)
        files = entries
        totalLength = total
        isMultiFile = multi

        let expected = (total + declaredLength - 1) / declaredLength
        guard expected == pieceHashes.count else {
            throw MetainfoError.pieceCountMismatch(hashes: pieceHashes.count, bytes: total,
                                                   pieceLength: declaredLength)
        }
    }

    /// Parse a whole .torrent file.
    static func parse(_ data: Data) throws -> Metainfo {
        let value: Bencode
        do { value = try Bencode.decode(data) } catch {
            throw MetainfoError.notATorrent(error.localizedDescription)
        }
        guard let info = value["info"] else {
            throw MetainfoError.notATorrent("no 'info' dictionary")
        }
        // Re-encoding the decoded info reproduces the original bytes, because
        // our encoder sorts keys exactly as bencode requires.
        return try Metainfo(rawInfo: info.encoded(), trackers: trackers(in: value))
    }

    static func parse(contentsOf url: URL) throws -> Metainfo {
        try parse(try Data(contentsOf: url))
    }

    /// Re-emit a .torrent file, splicing the original info bytes back in
    /// verbatim. "announce" < "announce-list" < "info", so the parts can simply
    /// be concatenated in that order.
    func torrentFileData() -> Data {
        var out = Data([UInt8(ascii: "d")])
        if let first = trackers.first {
            out.append(Bencode.string("announce").encoded())
            out.append(Bencode.string(first).encoded())
            out.append(Bencode.string("announce-list").encoded())
            out.append(Bencode.list(trackers.map { .list([.string($0)]) }).encoded())
        }
        out.append(Bencode.string("info").encoded())
        out.append(rawInfo)
        out.append(UInt8(ascii: "e"))
        return out
    }

    // MARK: - Helpers

    private static func parseFiles(info: Bencode, name: String) throws
        -> ([FileEntry], Int, Bool) {
        guard let rawFiles = info["files"] else {
            guard let length = info["length"]?.integerValue, length >= 0 else {
                throw MetainfoError.missingLength
            }
            return ([FileEntry(path: name, length: length, offset: 0)], length, false)
        }
        guard let items = rawFiles.listValue, !items.isEmpty else {
            throw MetainfoError.malformedFiles
        }

        var entries: [FileEntry] = []
        var offset = 0
        for (index, item) in items.enumerated() {
            guard item.dictionaryValue != nil else { throw MetainfoError.malformedFiles }
            guard let length = item["length"]?.integerValue, length >= 0 else {
                throw MetainfoError.malformedFiles
            }
            guard offset + length <= maxTotalLength else { throw MetainfoError.implausiblySized }
            let parts = (item["path"]?.listValue ?? []).compactMap {
                safeComponent($0.dataValue)
            }
            let relative = parts.isEmpty ? "file_\(index)" : parts.joined(separator: "/")
            entries.append(FileEntry(path: relative, length: length, offset: offset))
            offset += length
        }
        return (entries, offset, true)
    }

    /// Rejects path components that could escape the download directory.
    static func safeComponent(_ raw: Data?) -> String? {
        guard let raw else { return nil }
        let text = String(decoding: raw, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text == "." || text == ".." { return nil }
        if text.contains("/") || text.contains("\\") || text.contains("\0") { return nil }
        return text
    }

    private static func trackers(in meta: Bencode) -> [String] {
        var out: [String] = []
        func add(_ value: Bencode?) {
            guard let text = value?.stringValue?.trimmingCharacters(in: .whitespaces),
                  !text.isEmpty, !out.contains(text) else { return }
            out.append(text)
        }
        // announce-list is tiered; flatten it but keep tier order.
        for tier in meta["announce-list"]?.listValue ?? [] {
            if let urls = tier.listValue { urls.forEach(add) } else { add(tier) }
        }
        add(meta["announce"])
        return out
    }
}

// MARK: - Magnet links

struct MagnetLink {
    let infoHash: Data
    let displayName: String
    let trackers: [String]
    let peers: [String]     // x.pe= direct peer hints

    /// Parse a magnet: URI carrying a BitTorrent info-hash (BEP 9 / BEP 53).
    init(_ uri: String) throws {
        guard uri.lowercased().hasPrefix("magnet:") else { throw MetainfoError.notAMagnet }
        let query = String(uri.dropFirst("magnet:".count)).drop { $0 == "?" }

        var exactTopics: [String] = []
        var name = ""
        var trackerList: [String] = []
        var peerList: [String] = []

        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0])
            let value = String(parts[1])
                .replacingOccurrences(of: "+", with: " ")
                .removingPercentEncoding ?? String(parts[1])
            guard !value.isEmpty else { continue }
            switch key {
            case "xt": exactTopics.append(value)
            case "dn": if name.isEmpty { name = value }
            case "tr": trackerList.append(value)
            case "x.pe": peerList.append(value)
            default: break
            }
        }

        var hash: Data?
        for topic in exactTopics {
            let prefix = "urn:btih:"
            guard topic.lowercased().hasPrefix(prefix) else { continue }
            let digest = String(topic.dropFirst(prefix.count))
            if digest.count == 40, let decoded = Data(hexString: digest) {
                hash = decoded
            } else if digest.count == 32, let decoded = Data(base32: digest.uppercased()) {
                hash = decoded
            }
            if hash != nil { break }
        }

        guard let infoHash = hash else {
            if exactTopics.contains(where: { $0.lowercased().hasPrefix("urn:btmh:") }) {
                throw MetainfoError.versionTwoMagnet
            }
            throw MetainfoError.unusableMagnet
        }

        self.infoHash = infoHash
        self.displayName = name
        self.trackers = trackerList
        self.peers = peerList
    }
}

// MARK: - Byte helpers

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }

    /// RFC 4648 base32, which is how 32-character magnet hashes are written.
    init?(base32 text: String) {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0, accumulator = 0
        var bytes = [UInt8]()
        for character in text where character != "=" {
            guard let index = alphabet.firstIndex(of: character) else { return nil }
            accumulator = (accumulator << 5) | index
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((accumulator >> bits) & 0xFF))
            }
        }
        self = Data(bytes)
    }
}
