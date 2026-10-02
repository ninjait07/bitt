import Foundation
import Network

/// Lets exactly one caller through, however many threads race for it.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

/// A TCP stream with the two operations the peer protocol needs: read exactly
/// this many bytes, and write these bytes in order.
final class TCPConnection: @unchecked Sendable {
    enum ConnectionError: LocalizedError {
        case closed
        case timedOut
        case backlogged

        var errorDescription: String? {
            switch self {
            case .closed: return "connection closed"
            case .timedOut: return "connection timed out"
            case .backlogged: return "peer is not reading; dropping it"
            }
        }
    }

    /// Stop queueing writes once this many are still in flight — a peer that is
    /// not draining is dead weight, not something to buffer for.
    private static let maxOutstandingWrites = 64

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "bitt.tcp")
    private let lock = NSLock()
    private var outstandingWrites = 0
    private var cancelled = false

    let remote: PeerAddress

    init(connection: NWConnection, remote: PeerAddress) {
        self.connection = connection
        self.remote = remote
    }

    convenience init(host: String, port: Int) {
        let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) ?? 6881
        let parameters = NWParameters.tcp
        parameters.prohibitedInterfaceTypes = []
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort,
                                      using: parameters)
        self.init(connection: connection, remote: PeerAddress(host: host, port: port))
    }

    /// Bring the connection up, or throw if it cannot be established in time.
    func start(timeout: TimeInterval) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [connection, queue] in
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, Error>) in
                    // NWConnection can report several states in quick succession
                    // and a continuation may only be resumed once.
                    let once = OnceFlag()
                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            if once.claim() { continuation.resume() }
                        case .failed(let error):
                            if once.claim() { continuation.resume(throwing: error) }
                        case .cancelled:
                            if once.claim() { continuation.resume(throwing: ConnectionError.closed) }
                        default: break
                        }
                    }
                    if connection.state == .setup { connection.start(queue: queue) }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw ConnectionError.timedOut
            }
            try await group.next()
            group.cancelAll()
        }
    }

    /// An already-connected socket handed over by the listener.
    func adopt() {
        connection.stateUpdateHandler = nil
        if connection.state == .setup { connection.start(queue: queue) }
    }

    func readExactly(_ count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) {
                data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, data.count == count {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: ConnectionError.closed)
                } else {
                    continuation.resume(throwing: ConnectionError.closed)
                }
            }
        }
    }

    /// Fire-and-forget, but ordered: NWConnection sends in the order given.
    func write(_ data: Data) {
        lock.lock()
        if cancelled || outstandingWrites >= Self.maxOutstandingWrites {
            let overloaded = !cancelled
            lock.unlock()
            if overloaded { cancel() }
            return
        }
        outstandingWrites += 1
        lock.unlock()

        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.outstandingWrites -= 1
            self.lock.unlock()
        })
    }

    func cancel() {
        lock.lock()
        let alreadyCancelled = cancelled
        cancelled = true
        lock.unlock()
        guard !alreadyCancelled else { return }
        connection.cancel()
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
}
