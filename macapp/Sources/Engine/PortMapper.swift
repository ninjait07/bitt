import Foundation
import Network
import SystemConfiguration

/// Asks the router to forward our listening port.
///
/// NAT-PMP (RFC 6886) is tried first because it is a two-packet exchange, then
/// UPnP IGD, which is what most non-Apple consumer routers actually speak.
/// Being reachable is what lets other peers connect to us, and on a private
/// tracker that is most of the ratio. When neither works the app says so rather
/// than pretending the port is open.
actor PortMapper {
    enum Status: Sendable, Equatable {
        case idle
        case searching
        case mapped(external: Int)
        case unavailable(String)

        var summary: String {
            switch self {
            case .idle: return "not requested"
            case .searching: return "asking the router…"
            case .mapped(let port): return "router forwarded port \(port)"
            case .unavailable(let why): return why
            }
        }

        var isMapped: Bool { if case .mapped = self { return true }; return false }
    }

    private enum Method {
        case natPMP(gateway: String)
        case upnp(UPnP.Gateway)
    }

    private static let gatewayPort: UInt16 = 5351
    private static let requestedLifetime: UInt32 = 3600

    private(set) var status: Status = .idle
    private var internalPort = 0
    private var method: Method?
    private var renewal: Task<Void, Never>?

    /// Ask for a mapping and keep it renewed. Safe to call again.
    func start(internalPort port: Int) async {
        guard port > 0 else { return }
        internalPort = port
        renewal?.cancel()
        status = .searching
        method = nil

        if let gateway = PortMapper.defaultGateway() {
            await requestNATPMP(gateway: gateway)
        }

        if !status.isMapped, let gateway = await UPnP.discover() {
            method = .upnp(gateway)
            if let external = await UPnP.addMapping(gateway: gateway, port: port,
                                                    lifetime: Int(Self.requestedLifetime)) {
                status = .mapped(external: external)
            } else {
                status = .unavailable("router refused the request — forward port \(port) by hand")
            }
        } else if !status.isMapped, method == nil {
            status = .unavailable("router did not answer — forward port \(port) by hand")
        }

        guard status.isMapped else { return }
        renewal = Task { [weak self] in
            while !Task.isCancelled {
                // Renew at half the lifetime, as the RFC recommends.
                try? await Task.sleep(nanoseconds: UInt64(PortMapper.requestedLifetime / 2)
                                      * 1_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.renew()
            }
        }
    }

    private func renew() async {
        switch method {
        case .natPMP(let gateway):
            await requestNATPMP(gateway: gateway)
        case .upnp(let gateway):
            _ = await UPnP.addMapping(gateway: gateway, port: internalPort,
                                      lifetime: Int(Self.requestedLifetime))
        case nil:
            break
        }
    }

    func stop() async {
        renewal?.cancel()
        renewal = nil
        switch method {
        case .natPMP(let gateway):
            // Lifetime 0 asks the router to drop the mapping.
            _ = try? await exchange(gateway: gateway,
                                    packet: mapPacket(lifetime: 0),
                                    expectedOpcode: 0x82)
        case .upnp(let gateway):
            await UPnP.removeMapping(gateway: gateway, port: internalPort)
        case nil:
            break
        }
        method = nil
        status = .idle
    }

    // MARK: - Protocol

    private func requestNATPMP(gateway: String) async {
        do {
            let reply = try await exchange(gateway: gateway,
                                           packet: mapPacket(lifetime: Self.requestedLifetime),
                                           expectedOpcode: 0x82)
            let bytes = [UInt8](reply)
            guard bytes.count >= 16 else { return }
            let result = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
            guard result == 0 else { return }
            method = .natPMP(gateway: gateway)
            status = .mapped(external: Int(UInt16(bytes[10]) << 8 | UInt16(bytes[11])))
        } catch {
            // Fine: UPnP is tried next.
        }
    }

    /// A TCP map request for our listening port.
    private func mapPacket(lifetime: UInt32) -> Data {
        var packet = Data([0, 2, 0, 0])                       // version 0, opcode 2 (TCP)
        packet.append(UInt8(truncatingIfNeeded: internalPort >> 8))
        packet.append(UInt8(truncatingIfNeeded: internalPort))
        packet.append(UInt8(truncatingIfNeeded: internalPort >> 8))   // suggest the same port
        packet.append(UInt8(truncatingIfNeeded: internalPort))
        packet.append(bigEndian: lifetime)
        return packet
    }

    private func exchange(gateway: String, packet: Data, expectedOpcode: UInt8) async throws -> Data {
        guard let port = NWEndpoint.Port(rawValue: Self.gatewayPort) else {
            throw TrackerError.badURL
        }
        let socket = UDPSocket(host: NWEndpoint.Host(gateway), port: port)
        defer { socket.close() }
        try await socket.start()

        // RFC 6886 says 250 ms, doubling. Three tries is enough before moving
        // on to UPnP; a router that speaks NAT-PMP answers immediately.
        var timeout = 0.25
        for _ in 0..<3 {
            try await socket.send(packet)
            if let reply = try await socket.receive(timeout: timeout),
               reply.count >= 4, reply[reply.startIndex] == 0,
               reply[reply.startIndex + 1] == expectedOpcode {
                return reply
            }
            timeout *= 2
        }
        throw TrackerError.noResponse
    }

    // MARK: - Finding the router

    /// The default IPv4 router, straight from the system's network state.
    static func defaultGateway() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "BITT" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString)
                as? [String: Any],
              let router = value["Router"] as? String, !router.isEmpty else { return nil }
        return router
    }
}
