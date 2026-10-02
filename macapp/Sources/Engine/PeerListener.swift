import Foundation
import Network

/// One incoming-connection port shared by every torrent.
///
/// A client running several torrents should not open a port per torrent: peers
/// announce one port to the tracker, and the info-hash in the handshake says
/// which torrent the caller wants.
actor PeerListener {
    private var listener: NWListener?
    private var sessions: [Data: TorrentSession] = [:]
    private(set) var port = 0

    private let requestedPort: Int
    private let attempts: Int

    init(port: Int = 6881, attempts: Int = 10) {
        self.requestedPort = port
        self.attempts = attempts
    }

    func start() async -> Bool {
        for candidate in requestedPort..<(requestedPort + attempts) {
            guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(candidate)) else { continue }
            do {
                let listener = try NWListener(using: .tcp, on: endpointPort)
                listener.newConnectionHandler = { [weak self] connection in
                    Task { await self?.accept(connection) }
                }
                listener.start(queue: DispatchQueue(label: "bitt.listener"))
                self.listener = listener
                self.port = candidate
                return true
            } catch {
                continue
            }
        }
        port = 0
        return false
    }

    func register(_ session: TorrentSession, infoHash: Data) {
        sessions[infoHash] = session
    }

    func unregister(infoHash: Data) {
        sessions.removeValue(forKey: infoHash)
    }

    private func accept(_ connection: NWConnection) async {
        let remote = PeerListener.address(of: connection)
        let stream = TCPConnection(connection: connection, remote: remote)
        stream.adopt()

        do {
            let raw = try await withTimeout(15) { try await stream.readExactly(Wire.handshakeLength) }
            let handshake = try Wire.parseHandshake(raw)
            guard let session = sessions[handshake.infoHash] else {
                stream.cancel()
                return
            }
            await session.adoptIncoming(stream: stream, handshake: handshake)
        } catch {
            stream.cancel()
        }
    }

    private static func address(of connection: NWConnection) -> PeerAddress {
        if case .hostPort(let host, let port) = connection.endpoint {
            var text = "\(host)"
            // NWEndpoint.Host prints IPv6 with a %interface suffix; trim it.
            if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
            return PeerAddress(host: text, port: Int(port.rawValue))
        }
        return PeerAddress(host: "?", port: 0)
    }

    func close() {
        sessions.removeAll()
        listener?.cancel()
        listener = nil
    }
}
