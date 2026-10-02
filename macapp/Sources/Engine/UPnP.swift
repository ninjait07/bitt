import Foundation

/// UPnP Internet Gateway Device: the port-forwarding protocol most consumer
/// routers actually speak, where NAT-PMP is mostly an Apple thing.
enum UPnP {
    struct Gateway: Sendable {
        let controlURL: URL
        let serviceType: String
        let localAddress: String
    }

    static let description = "BITT"
    private static let serviceTypes = [
        "urn:schemas-upnp-org:service:WANIPConnection:1",
        "urn:schemas-upnp-org:service:WANPPPConnection:1",
    ]

    // MARK: - Discovery

    static func discover(timeout: TimeInterval = 3) async -> Gateway? {
        let locations = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: ssdpSearch(timeout: timeout))
            }
        }
        for location in locations {
            if let gateway = await describe(location: location) { return gateway }
        }
        return nil
    }

    /// An M-SEARCH on the SSDP multicast group. Replies come back as unicast
    /// from the router, so this needs an unconnected socket.
    private static func ssdpSearch(timeout: TimeInterval) -> [URL] {
        let handle = socket(AF_INET, SOCK_DGRAM, 0)
        guard handle >= 0 else { return [] }
        defer { close(handle) }

        var reuse: Int32 = 1
        setsockopt(handle, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var timeval = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(handle, SOL_SOCKET, SO_RCVTIMEO, &timeval,
                   socklen_t(MemoryLayout<timeval>.size))

        var destination = sockaddr_in()
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = UInt16(1900).bigEndian
        destination.sin_addr.s_addr = inet_addr("239.255.255.250")

        var found: [URL] = []
        for serviceType in ["urn:schemas-upnp-org:device:InternetGatewayDevice:1", "ssdp:all"] {
            let message = """
            M-SEARCH * HTTP/1.1\r
            HOST: 239.255.255.250:1900\r
            MAN: "ssdp:discover"\r
            MX: 2\r
            ST: \(serviceType)\r
            \r

            """
            let payload = [UInt8](message.utf8)
            let sent = withUnsafePointer(to: &destination) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    sendto(handle, payload, payload.count, 0, address,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard sent > 0 else { continue }

            let deadline = Date().addingTimeInterval(timeout)
            var buffer = [UInt8](repeating: 0, count: 4096)
            while Date() < deadline {
                let count = recv(handle, &buffer, buffer.count, 0)
                guard count > 0 else { break }
                let reply = String(decoding: buffer[0..<count], as: UTF8.self)
                if let location = header("LOCATION", in: reply),
                   let url = URL(string: location), !found.contains(url) {
                    found.append(url)
                }
            }
            if !found.isEmpty { break }
        }
        return found
    }

    private static func header(_ name: String, in message: String) -> String? {
        for line in message.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces).uppercased() == name else { continue }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    // MARK: - Device description

    private static func describe(location: URL) async -> Gateway? {
        guard let (data, _) = try? await URLSession.shared.data(from: location),
              let service = ServiceFinder.find(in: data, matching: serviceTypes) else { return nil }

        // controlURL may be relative to the description's own URL.
        guard let controlURL = URL(string: service.controlURL, relativeTo: location)?.absoluteURL,
              let host = location.host, let localAddress = localAddress(reaching: host) else {
            return nil
        }
        return Gateway(controlURL: controlURL, serviceType: service.type,
                       localAddress: localAddress)
    }

    /// Our address on the interface that reaches the router — that is what the
    /// mapping has to point at.
    static func localAddress(reaching host: String) -> String? {
        let handle = socket(AF_INET, SOCK_DGRAM, 0)
        guard handle >= 0 else { return nil }
        defer { close(handle) }

        var destination = sockaddr_in()
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = UInt16(9).bigEndian     // discard port; nothing is sent
        destination.sin_addr.s_addr = inet_addr(host)
        guard destination.sin_addr.s_addr != INADDR_NONE else { return nil }

        let connected = withUnsafePointer(to: &destination) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }

        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let read = withUnsafeMutablePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(handle, $0, &length)
            }
        }
        guard read == 0 else { return nil }
        return String(cString: inet_ntoa(local.sin_addr))
    }

    // MARK: - Mapping

    /// Returns the external port the router agreed to, or nil.
    static func addMapping(gateway: Gateway, port: Int, lifetime: Int) async -> Int? {
        if await soap(gateway: gateway, action: "AddPortMapping",
                      arguments: mappingArguments(gateway: gateway, port: port,
                                                  lifetime: lifetime)) {
            return port
        }
        // Plenty of routers only accept permanent leases (error 725).
        if lifetime > 0,
           await soap(gateway: gateway, action: "AddPortMapping",
                      arguments: mappingArguments(gateway: gateway, port: port, lifetime: 0)) {
            return port
        }
        return nil
    }

    static func removeMapping(gateway: Gateway, port: Int) async {
        _ = await soap(gateway: gateway, action: "DeletePortMapping", arguments: [
            ("NewRemoteHost", ""),
            ("NewExternalPort", String(port)),
            ("NewProtocol", "TCP"),
        ])
    }

    private static func mappingArguments(gateway: Gateway, port: Int,
                                         lifetime: Int) -> [(String, String)] {
        [
            ("NewRemoteHost", ""),
            ("NewExternalPort", String(port)),
            ("NewProtocol", "TCP"),
            ("NewInternalPort", String(port)),
            ("NewInternalClient", gateway.localAddress),
            ("NewEnabled", "1"),
            ("NewPortMappingDescription", description),
            ("NewLeaseDuration", String(lifetime)),
        ]
    }

    private static func soap(gateway: Gateway, action: String,
                             arguments: [(String, String)]) async -> Bool {
        let body = arguments
            .map { "<\($0.0)>\(escape($0.1))</\($0.0)>" }
            .joined()
        let envelope = """
        <?xml version="1.0"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
        s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
        <s:Body><u:\(action) xmlns:u="\(gateway.serviceType)">\(body)</u:\(action)></s:Body>
        </s:Envelope>
        """

        var request = URLRequest(url: gateway.controlURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(gateway.serviceType)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        request.httpBody = Data(envelope.utf8)

        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200...299).contains(http.statusCode)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// Pulls the WAN connection service out of a device description document.
private final class ServiceFinder: NSObject, XMLParserDelegate {
    struct Service { let type: String; let controlURL: String }

    private let wanted: [String]
    private var element = ""
    private var text = ""
    private var currentType = ""
    private var currentControl = ""
    private var result: Service?

    private init(wanted: [String]) { self.wanted = wanted }

    static func find(in data: Data, matching wanted: [String]) -> Service? {
        let finder = ServiceFinder(wanted: wanted)
        let parser = XMLParser(data: data)
        parser.delegate = finder
        parser.parse()
        return finder.result
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        element = name
        text = ""
        if name == "service" {
            currentType = ""
            currentControl = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "serviceType": currentType = value
        case "controlURL": currentControl = value
        case "service":
            if result == nil, wanted.contains(currentType), !currentControl.isEmpty {
                result = Service(type: currentType, controlURL: currentControl)
                parser.abortParsing()
            }
        default: break
        }
        text = ""
    }
}
