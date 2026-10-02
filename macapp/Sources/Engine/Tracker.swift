import Foundation
import Network

struct PeerAddress: Hashable, CustomStringConvertible {
    let host: String
    let port: Int
    var description: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }

    /// Parse host:port, including [v6]:port.
    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let host: String, portText: String
        if trimmed.hasPrefix("[") {
            guard let end = trimmed.firstIndex(of: "]") else { return nil }
            host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<end])
            let rest = trimmed[trimmed.index(after: end)...]
            guard rest.hasPrefix(":") else { return nil }
            portText = String(rest.dropFirst())
        } else {
            let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            host = String(parts[0])
            portText = String(parts[1])
        }
        guard let port = Int(portText), port > 0, port < 65536, !host.isEmpty else { return nil }
        self.host = host
        self.port = port
    }

    init(host: String, port: Int) { self.host = host; self.port = port }
}

struct TrackerResponse {
    var peers: [PeerAddress] = []
    var interval = 1800
    var seeders = 0
    var leechers = 0
    var warning = ""
}

enum TrackerEvent: String {
    case none, completed, started, stopped
    var udpCode: UInt32 {
        switch self {
        case .none: return 0
        case .completed: return 1
        case .started: return 2
        case .stopped: return 3
        }
    }
}

enum TrackerError: LocalizedError {
    case unsupportedScheme(String)
    case failure(String)
    case malformedResponse
    case noResponse
    case badURL

    var errorDescription: String? {
        switch self {
        case .unsupportedScheme(let scheme): return "unsupported tracker scheme: \(scheme)"
        case .failure(let message): return message
        case .malformedResponse: return "tracker sent a malformed response"
        case .noResponse: return "no response from tracker"
        case .badURL: return "tracker URL is not usable"
        }
    }
}

/// A single tracker URL, with its own retry and backoff state.
final class Tracker {
    let url: String
    let scheme: String

    var nextAnnounceAt: TimeInterval = 0
    var interval = 0
    var failures = 0
    var lastError = ""
    var lastPeerCount = 0

    init(url: String) throws {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        guard let parsed = URL(string: trimmed), let scheme = parsed.scheme?.lowercased(),
              ["http", "https", "udp"].contains(scheme) else {
            throw TrackerError.unsupportedScheme(URL(string: trimmed)?.scheme ?? "?")
        }
        self.url = trimmed
        self.scheme = scheme
    }

    var isDue: Bool { Date().timeIntervalSinceReferenceDate >= nextAnnounceAt }

    func schedule(after seconds: TimeInterval) {
        nextAnnounceAt = Date().timeIntervalSinceReferenceDate + seconds
    }

    func noteFailure(_ error: Error) {
        failures += 1
        lastError = error.localizedDescription
        // Back off 30s, 60s, 120s … capped at 15 minutes.
        schedule(after: min(30 * pow(2, Double(min(failures - 1, 5))), 900))
    }

    func noteSuccess(_ response: TrackerResponse) {
        failures = 0
        lastError = ""
        lastPeerCount = response.peers.count
        interval = response.interval
        schedule(after: Double(max(60, min(response.interval, 3600))))
    }

    struct AnnounceRequest {
        let infoHash: Data
        let peerID: Data
        let port: Int
        let uploaded: Int
        let downloaded: Int
        let left: Int
        var event: TrackerEvent = .none
        var numWant = 80
        var key: UInt32 = UInt32.random(in: 0...UInt32.max)
    }

    func announce(_ request: AnnounceRequest) async throws -> TrackerResponse {
        scheme == "udp"
            ? try await UDPTracker.announce(url: url, request: request)
            : try await HTTPTracker.announce(url: url, request: request)
    }

    /// Build the trackers for a torrent, dropping duplicates and unusable URLs.
    static func build(_ urls: [String]) -> [Tracker] {
        var seen = Set<String>()
        var out: [Tracker] = []
        for url in urls {
            let clean = url.trimmingCharacters(in: .whitespaces)
            guard !clean.isEmpty, seen.insert(clean).inserted else { continue }
            if let tracker = try? Tracker(url: clean) { out.append(tracker) }
        }
        return out.shuffled()
    }
}

// MARK: - HTTP (BEP 3, BEP 23)

enum HTTPTracker {
    static func announce(url: String, request: Tracker.AnnounceRequest) async throws
        -> TrackerResponse {
        var query = [
            "info_hash=" + percentEncode(request.infoHash),
            "peer_id=" + percentEncode(request.peerID),
            "port=\(request.port)",
            "uploaded=\(request.uploaded)",
            "downloaded=\(request.downloaded)",
            "left=\(request.left)",
            "compact=1",
            "numwant=\(request.numWant)",
            "key=" + String(format: "%08x", request.key),
        ]
        if request.event != .none { query.append("event=\(request.event.rawValue)") }

        let separator = url.contains("?") ? "&" : "?"
        guard let target = URL(string: url + separator + query.joined(separator: "&")) else {
            throw TrackerError.badURL
        }

        var urlRequest = URLRequest(url: target)
        urlRequest.timeoutInterval = 20
        urlRequest.setValue("BITT/1.0", forHTTPHeaderField: "User-Agent")
        urlRequest.setValue("close", forHTTPHeaderField: "Connection")

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw TrackerError.failure("HTTP \(http.statusCode) from tracker")
        }
        return try parse(data)
    }

    /// Percent-encode raw bytes: a 20-byte info-hash is not text.
    static func percentEncode(_ data: Data) -> String {
        let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~".utf8)
        var out = ""
        out.reserveCapacity(data.count * 3)
        for byte in data {
            if unreserved.contains(byte) {
                out.append(Character(UnicodeScalar(byte)))
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    static func parse(_ data: Data) throws -> TrackerResponse {
        guard let value = try? Bencode.decode(data), value.dictionaryValue != nil else {
            throw TrackerError.malformedResponse
        }
        if let failure = value["failure reason"]?.stringValue, !failure.isEmpty {
            throw TrackerError.failure(failure)
        }

        var response = TrackerResponse()
        response.interval = value["interval"]?.integerValue ?? 1800
        if response.interval <= 0 { response.interval = 1800 }
        response.seeders = value["complete"]?.integerValue ?? 0
        response.leechers = value["incomplete"]?.integerValue ?? 0
        response.warning = value["warning message"]?.stringValue ?? ""

        var peers: [PeerAddress] = []
        switch value["peers"] {
        case .string(let compact): peers += unpackCompact(compact, addressSize: 4)
        case .list(let entries):
            for entry in entries {
                if let ip = entry["ip"]?.stringValue, let port = entry["port"]?.integerValue {
                    peers.append(PeerAddress(host: ip, port: port))
                }
            }
        default: break
        }
        if let compact6 = value["peers6"]?.dataValue {
            peers += unpackCompact(compact6, addressSize: 16)
        }

        var seen = Set<PeerAddress>()
        response.peers = peers.filter { seen.insert($0).inserted }
        return response
    }

    static func unpackCompact(_ raw: Data, addressSize: Int) -> [PeerAddress] {
        let stride = addressSize + 2
        var out: [PeerAddress] = []
        let bytes = [UInt8](raw)
        var offset = 0
        while offset + stride <= bytes.count {
            let addressBytes = Array(bytes[offset..<(offset + addressSize)])
            let port = Int(bytes[offset + addressSize]) << 8 | Int(bytes[offset + addressSize + 1])
            offset += stride
            guard port > 0, let host = formatAddress(addressBytes) else { continue }
            out.append(PeerAddress(host: host, port: port))
        }
        return out
    }

    static func formatAddress(_ bytes: [UInt8]) -> String? {
        if bytes.count == 4 {
            return bytes.map(String.init).joined(separator: ".")
        }
        if bytes.count == 16 {
            let groups = stride(from: 0, to: 16, by: 2).map {
                String(format: "%x", Int(bytes[$0]) << 8 | Int(bytes[$0 + 1]))
            }
            return groups.joined(separator: ":")
        }
        return nil
    }
}

// MARK: - UDP (BEP 15)

private enum UDPTracker {
    static let protocolID: UInt64 = 0x41727101980

    static func announce(url: String, request: Tracker.AnnounceRequest) async throws
        -> TrackerResponse {
        guard let parsed = URL(string: url), let host = parsed.host, let port = parsed.port,
              let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw TrackerError.badURL
        }

        let socket = UDPSocket(host: NWEndpoint.Host(host), port: nwPort)
        defer { socket.close() }
        try await socket.start()

        let connectionID = try await connect(socket)

        let transactionID = UInt32.random(in: 0...UInt32.max)
        var packet = Data()
        packet.append(bigEndian: connectionID)
        packet.append(bigEndian: UInt32(1))               // action: announce
        packet.append(bigEndian: transactionID)
        packet.append(request.infoHash)
        packet.append(request.peerID)
        packet.append(bigEndian: UInt64(request.downloaded))
        packet.append(bigEndian: UInt64(request.left))
        packet.append(bigEndian: UInt64(request.uploaded))
        packet.append(bigEndian: request.event.udpCode)
        packet.append(bigEndian: UInt32(0))               // IP: let the tracker decide
        packet.append(bigEndian: request.key)
        packet.append(bigEndian: UInt32(bitPattern: Int32(request.numWant)))
        packet.append(UInt8(truncatingIfNeeded: request.port >> 8))   // port is 16 bits
        packet.append(UInt8(truncatingIfNeeded: request.port))

        let body = try await exchange(socket, packet: packet, transactionID: transactionID,
                                      expecting: 1, minimumLength: 12)

        var response = TrackerResponse()
        response.interval = Int(body.readUInt32(at: 0) ?? 1800)
        if response.interval <= 0 { response.interval = 1800 }
        response.leechers = Int(body.readUInt32(at: 4) ?? 0)
        response.seeders = Int(body.readUInt32(at: 8) ?? 0)
        let peers = HTTPTracker.unpackCompact(Data(body.dropFirst(12)), addressSize: 4)
        var seen = Set<PeerAddress>()
        response.peers = peers.filter { seen.insert($0).inserted }
        return response
    }

    private static func connect(_ socket: UDPSocket) async throws -> UInt64 {
        let transactionID = UInt32.random(in: 0...UInt32.max)
        var packet = Data()
        packet.append(bigEndian: protocolID)
        packet.append(bigEndian: UInt32(0))               // action: connect
        packet.append(bigEndian: transactionID)
        let body = try await exchange(socket, packet: packet, transactionID: transactionID,
                                      expecting: 0, minimumLength: 8)
        return body.readUInt64(at: 0) ?? 0
    }

    /// Send and wait for the matching reply, retrying the way BEP 15 asks.
    private static func exchange(_ socket: UDPSocket, packet: Data, transactionID: UInt32,
                                 expecting action: UInt32, minimumLength: Int) async throws -> Data {
        for attempt in 0..<3 {
            try await socket.send(packet)
            let timeout: TimeInterval = attempt == 0 ? 8 : min(15 * pow(2, Double(attempt)), 60)
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                guard let reply = try await socket.receive(timeout: deadline.timeIntervalSinceNow),
                      reply.count >= 8,
                      let replyAction = reply.readUInt32(at: 0),
                      let replyTransaction = reply.readUInt32(at: 4) else { break }
                guard replyTransaction == transactionID else { continue }
                if replyAction == 3 {
                    let message = String(decoding: reply.dropFirst(8), as: UTF8.self)
                    throw TrackerError.failure(message.isEmpty ? "tracker error" : message)
                }
                guard replyAction == action, reply.count >= 8 + minimumLength else { continue }
                return Data(reply.dropFirst(8))
            }
        }
        throw TrackerError.noResponse
    }
}

/// A minimal datagram socket with an async send and a timed receive.
final class UDPSocket: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "bitt.udp")

    init(host: NWEndpoint.Host, port: NWEndpoint.Port) {
        connection = NWConnection(host: host, port: port, using: .udp)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    if once.claim() { continuation.resume(throwing: error) }
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    /// Returns nil when nothing arrives before the timeout.
    ///
    /// A task group cannot be used here: cancelling the group does not resume a
    /// pending `receiveMessage` continuation, so the group would wait on it for
    /// ever. One continuation with a race between the callback and a timer is
    /// both simpler and correct.
    func receive(timeout: TimeInterval) async throws -> Data? {
        guard timeout > 0 else { return nil }
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data?, Error>) in
            let once = OnceFlag()
            connection.receiveMessage { data, _, _, error in
                guard once.claim() else { return }
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: data) }
            }
            queue.asyncAfter(deadline: .now() + timeout) {
                guard once.claim() else { return }
                continuation.resume(returning: nil)
            }
        }
    }

    func close() { connection.cancel() }
}

// MARK: - Byte helpers

extension Data {
    mutating func append(bigEndian value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    func readUInt64(at offset: Int) -> UInt64? {
        guard count >= offset + 8 else { return nil }
        let start = index(startIndex, offsetBy: offset)
        return self[start..<index(start, offsetBy: 8)]
            .reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}
