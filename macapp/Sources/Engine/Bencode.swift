import Foundation

/// Bencode (BEP 3).
///
/// Strings stay as `Data` and dictionary keys are never decoded to `String`: a
/// torrent's `info` dictionary has to survive a decode/encode round trip
/// byte-for-byte, otherwise the info-hash changes.
indirect enum Bencode: Equatable {
    case integer(Int)
    case string(Data)
    case list([Bencode])
    case dictionary([Data: Bencode])
}

enum BencodeError: LocalizedError, Equatable {
    case unexpectedEnd
    case invalidToken(UInt8, at: Int)
    case malformedInteger(at: Int)
    case malformedLength(at: Int)
    case truncatedString(at: Int)
    case unterminated(String)
    case keyNotAString(at: Int)
    case trailingData(at: Int)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .unexpectedEnd: return "unexpected end of data"
        case .invalidToken(let byte, let index):
            return "invalid token \(Character(UnicodeScalar(byte))) at \(index)"
        case .malformedInteger(let index): return "malformed integer at \(index)"
        case .malformedLength(let index): return "malformed string length at \(index)"
        case .truncatedString(let index): return "string at \(index) runs past the end of the data"
        case .unterminated(let what): return "unterminated \(what)"
        case .keyNotAString(let index): return "dictionary key at \(index) is not a string"
        case .trailingData(let index): return "trailing data after the bencoded value at \(index)"
        case .unsupported(let what): return "cannot bencode \(what)"
        }
    }
}

// MARK: - Decoding

extension Bencode {
    /// Decode one complete value. Anything left over is an error.
    static func decode(_ data: Data) throws -> Bencode {
        var index = data.startIndex
        let value = try decode(data, from: &index)
        guard index == data.endIndex else { throw BencodeError.trailingData(at: index) }
        return value
    }

    /// Decode one value and leave `index` just past it, so trailing bytes can be
    /// read by the caller (ut_metadata messages need this).
    static func decodePrefix(_ data: Data, from index: inout Data.Index) throws -> Bencode {
        try decode(data, from: &index)
    }

    private static func decode(_ data: Data, from index: inout Data.Index) throws -> Bencode {
        guard index < data.endIndex else { throw BencodeError.unexpectedEnd }
        switch data[index] {
        case UInt8(ascii: "i"): return try decodeInteger(data, from: &index)
        case UInt8(ascii: "l"): return try decodeList(data, from: &index)
        case UInt8(ascii: "d"): return try decodeDictionary(data, from: &index)
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return .string(try decodeString(data, from: &index))
        case let byte: throw BencodeError.invalidToken(byte, at: index)
        }
    }

    private static func decodeInteger(_ data: Data, from index: inout Data.Index) throws -> Bencode {
        let start = index
        index = data.index(after: index)
        guard let end = data[index...].firstIndex(of: UInt8(ascii: "e")) else {
            throw BencodeError.unterminated("integer")
        }
        let raw = data[index..<end]
        guard let text = String(data: raw, encoding: .ascii), let value = Int(text),
              isCanonicalInteger(text) else {
            throw BencodeError.malformedInteger(at: start)
        }
        index = data.index(after: end)
        return .integer(value)
    }

    /// Rejects "03", "-0" and "" the way the spec requires.
    private static func isCanonicalInteger(_ text: String) -> Bool {
        if text.isEmpty || text == "-" || text.hasPrefix("-0") { return false }
        if text.count > 1 && text.hasPrefix("0") { return false }
        return true
    }

    private static func decodeString(_ data: Data, from index: inout Data.Index) throws -> Data {
        let start = index
        guard let colon = data[index...].firstIndex(of: UInt8(ascii: ":")) else {
            throw BencodeError.malformedLength(at: start)
        }
        let rawLength = data[index..<colon]
        guard let text = String(data: rawLength, encoding: .ascii),
              !text.isEmpty, text.allSatisfy(\.isNumber),
              !(text.count > 1 && text.hasPrefix("0")),
              let length = Int(text) else {
            throw BencodeError.malformedLength(at: start)
        }
        let begin = data.index(after: colon)
        guard let end = data.index(begin, offsetBy: length, limitedBy: data.endIndex) else {
            throw BencodeError.truncatedString(at: start)
        }
        index = end
        return Data(data[begin..<end])
    }

    private static func decodeList(_ data: Data, from index: inout Data.Index) throws -> Bencode {
        index = data.index(after: index)
        var items: [Bencode] = []
        while true {
            guard index < data.endIndex else { throw BencodeError.unterminated("list") }
            if data[index] == UInt8(ascii: "e") {
                index = data.index(after: index)
                return .list(items)
            }
            items.append(try decode(data, from: &index))
        }
    }

    private static func decodeDictionary(_ data: Data, from index: inout Data.Index) throws -> Bencode {
        index = data.index(after: index)
        var pairs: [Data: Bencode] = [:]
        while true {
            guard index < data.endIndex else { throw BencodeError.unterminated("dictionary") }
            if data[index] == UInt8(ascii: "e") {
                index = data.index(after: index)
                return .dictionary(pairs)
            }
            let keyStart = index
            guard data[index] >= UInt8(ascii: "0"), data[index] <= UInt8(ascii: "9") else {
                throw BencodeError.keyNotAString(at: keyStart)
            }
            let key = try decodeString(data, from: &index)
            pairs[key] = try decode(data, from: &index)
        }
    }
}

// MARK: - Encoding

extension Bencode {
    func encoded() -> Data {
        var out = Data()
        encode(into: &out)
        return out
    }

    private func encode(into out: inout Data) {
        switch self {
        case .integer(let value):
            out.append(UInt8(ascii: "i"))
            out.append(contentsOf: Array(String(value).utf8))
            out.append(UInt8(ascii: "e"))
        case .string(let bytes):
            out.append(contentsOf: Array(String(bytes.count).utf8))
            out.append(UInt8(ascii: ":"))
            out.append(bytes)
        case .list(let items):
            out.append(UInt8(ascii: "l"))
            items.forEach { $0.encode(into: &out) }
            out.append(UInt8(ascii: "e"))
        case .dictionary(let pairs):
            out.append(UInt8(ascii: "d"))
            // Keys are sorted as raw byte strings, which is what the spec says
            // and what every other client assumes when it hashes the info dict.
            for key in pairs.keys.sorted(by: Bencode.bytesAreOrdered) {
                Bencode.string(key).encode(into: &out)
                pairs[key]!.encode(into: &out)
            }
            out.append(UInt8(ascii: "e"))
        }
    }

    static func bytesAreOrdered(_ lhs: Data, _ rhs: Data) -> Bool {
        for (left, right) in zip(lhs, rhs) where left != right { return left < right }
        return lhs.count < rhs.count
    }
}

// MARK: - Convenience accessors

extension Bencode {
    var integerValue: Int? { if case .integer(let value) = self { return value }; return nil }
    var dataValue: Data? { if case .string(let value) = self { return value }; return nil }
    var listValue: [Bencode]? { if case .list(let value) = self { return value }; return nil }
    var dictionaryValue: [Data: Bencode]? {
        if case .dictionary(let value) = self { return value }
        return nil
    }

    var stringValue: String? {
        guard let data = dataValue else { return nil }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    subscript(key: String) -> Bencode? {
        dictionaryValue?[Data(key.utf8)]
    }
}

extension Bencode {
    static func string(_ text: String) -> Bencode { .string(Data(text.utf8)) }
}

extension Data {
    /// Short-hand for a literal byte string, which bencode needs everywhere.
    init(ascii text: String) { self = Data(text.utf8) }
    var asciiString: String { String(decoding: self, as: UTF8.self) }
}
