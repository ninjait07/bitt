import Foundation

/// One peer connection: handshake, state machine, download and upload.
actor PeerConnection {
    static let connectTimeout: TimeInterval = 12
    static let handshakeTimeout: TimeInterval = 15
    static let idleTimeout: TimeInterval = 150
    static let keepAliveInterval: TimeInterval = 90

    static let minPipeline = 4
    static let maxPipeline = 96
    static let maxUploadQueue = 64
    /// Refuse silly upload requests.
    static let maxBlockRequest = 128 * 1024

    private static let keyLock = NSLock()
    private static var nextKey = 0
    private static func makeKey() -> Int {
        keyLock.lock(); defer { keyLock.unlock() }
        nextKey += 1
        return nextKey
    }

    let key: Int
    let address: PeerAddress
    let isIncoming: Bool

    private unowned let session: TorrentSession
    private let stream: TCPConnection

    // Wire state
    private(set) var amChoking = true
    private(set) var amInterested = false
    private(set) var peerChoking = true
    private(set) var peerInterested = false

    private(set) var peerID: Data?
    private(set) var clientName = ""
    private(set) var supportsExtensions = false
    private var utMetadataID: UInt8?
    private var metadataSize: Int?
    private var requestedMetadataPieces: Set<Int> = []

    // A magnet peer announces what it has before we know the piece count, so
    // those announcements wait here until the metadata arrives.
    private var deferredBitfield: Data?
    private var deferredHave: [Int] = []

    private var pending: [BlockKey: Int] = [:]   // (index, begin) -> block length
    private var pipeline = 8
    private(set) var bytesDownloaded = 0
    private(set) var bytesUploaded = 0
    private var windowBytes = 0
    private var windowStarted = Date().timeIntervalSinceReferenceDate
    private(set) var downloadRate: Double = 0
    private var lastMessageAt = Date().timeIntervalSinceReferenceDate

    private var uploadQueue: [(index: Int, begin: Int, length: Int)] = []
    private var uploading = false
    private var sentBitfield = false
    private(set) var isClosed = false

    struct BlockKey: Hashable { let index: Int; let begin: Int }

    init(session: TorrentSession, stream: TCPConnection, incoming: Bool) {
        self.key = PeerConnection.makeKey()
        self.session = session
        self.stream = stream
        self.address = stream.remote
        self.isIncoming = incoming
    }

    var describedName: String {
        let who = clientName.isEmpty
            ? (peerID.map { String(decoding: $0.prefix(8), as: UTF8.self) } ?? "?")
            : clientName
        return "\(address) (\(who))"
    }

    // MARK: - Lifecycle

    func run() async {
        do {
            if !isIncoming {
                try await stream.start(timeout: Self.connectTimeout)
                try await exchangeHandshake()
            } else {
                stream.adopt()
                stream.write(Wire.makeHandshake(infoHash: await session.infoHash,
                                                peerID: await session.peerID))
            }
            await session.peerBecameReady(self)
            await afterHandshake()

            let ticker = Task { [weak self] in await self?.tickLoop() }
            defer { ticker.cancel() }
            try await receiveLoop()
        } catch {
            await session.log(peerError: error, from: describedName)
        }
        await close()
    }

    private func exchangeHandshake() async throws {
        let ours = Wire.makeHandshake(infoHash: await session.infoHash,
                                      peerID: await session.peerID)
        stream.write(ours)
        let raw = try await withTimeout(Self.handshakeTimeout) { [stream] in
            try await stream.readExactly(Wire.handshakeLength)
        }
        let shake = try Wire.parseHandshake(raw)
        guard shake.infoHash == (await session.infoHash) else {
            throw Wire.WireError.malformed("peer offered a different torrent")
        }
        adopt(handshake: shake)
        guard shake.peerID != (await session.peerID) else {
            throw Wire.WireError.malformed("connected to ourselves")
        }
    }

    /// Take over a handshake the listener already read for us.
    func adopt(handshake: Wire.Handshake) {
        peerID = handshake.peerID
        supportsExtensions = handshake.supportsExtensions
        clientName = Wire.clientName(peerID: handshake.peerID)
    }

    private func afterHandshake() async {
        if supportsExtensions {
            stream.write(Wire.extendedHandshake(metadataSize: await session.metadataSize,
                                                clientVersion: TorrentSession.clientVersion,
                                                listenPort: await session.listenPort))
        }
        if await session.hasMetadata { sendBitfield(await session.currentBitfield()) }
    }

    private func sendBitfield(_ bits: Data?) {
        guard !sentBitfield, let bits, bits.contains(where: { $0 != 0 }) else { return }
        sentBitfield = true
        stream.write(Wire.bitfield(bits))
    }

    /// Send a pre-built frame, such as a HAVE broadcast.
    func send(raw frame: Data) {
        guard !isClosed else { return }
        stream.write(frame)
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        stream.cancel()
        await session.peerWentAway(self)
    }

    // MARK: - Receiving

    private func receiveLoop() async throws {
        while !isClosed {
            let header = try await stream.readExactly(4)
            let length = Int(header.readUInt32(at: 0) ?? 0)
            lastMessageAt = Date().timeIntervalSinceReferenceDate
            if length == 0 { continue }                       // keep-alive
            guard length <= Wire.maxMessageLength else {
                throw Wire.WireError.oversizedMessage(length)
            }
            let body = try await stream.readExactly(length)
            let id = body[body.startIndex]
            let payload = Data(body.dropFirst())
            try await handle(messageID: id, payload: payload)
        }
    }

    private func handle(messageID: UInt8, payload: Data) async throws {
        guard let id = Wire.MessageID(rawValue: messageID) else { return }
        switch id {
        case .choke:
            peerChoking = true
            await session.releaseRequests(of: key)
            pending.removeAll()

        case .unchoke:
            peerChoking = false
            await requestMore()

        case .interested:
            peerInterested = true
            await session.considerUnchoking(self)

        case .notInterested:
            peerInterested = false

        case .have:
            guard let index = payload.readUInt32(at: 0) else {
                throw Wire.WireError.malformed("have")
            }
            if await session.piecesReady {
                await session.peer(key, hasPiece: Int(index))
                await updateInterest()
                await requestMore()
            } else {
                deferredHave.append(Int(index))
            }

        case .bitfield:
            if await session.piecesReady {
                await session.peer(key, hasBitfield: payload)
                await updateInterest()
                await requestMore()
            } else {
                deferredBitfield = payload
            }

        case .request:
            guard payload.count == 12,
                  let index = payload.readUInt32(at: 0),
                  let begin = payload.readUInt32(at: 4),
                  let length = payload.readUInt32(at: 8) else {
                throw Wire.WireError.malformed("request")
            }
            try await queueUpload(index: Int(index), begin: Int(begin), length: Int(length))

        case .cancel:
            break   // we serve requests promptly; nothing sits queued long enough

        case .piece:
            guard payload.count >= 8,
                  let index = payload.readUInt32(at: 0),
                  let begin = payload.readUInt32(at: 4) else {
                throw Wire.WireError.malformed("piece")
            }
            await received(index: Int(index), begin: Int(begin),
                           block: Data(payload.dropFirst(8)))

        case .port:
            break   // DHT node announcement; we do not run a DHT node

        case .extended:
            try await handleExtended(payload)
        }
    }

    private func received(index: Int, begin: Int, block: Data) async {
        pending.removeValue(forKey: BlockKey(index: index, begin: begin))
        bytesDownloaded += block.count
        windowBytes += block.count
        await session.blockArrived(from: self, index: index, begin: begin, block: block)
        await requestMore()
    }

    private func updateInterest() async {
        let wanted = await session.peerIsUseful(key)
        if wanted && !amInterested {
            amInterested = true
            stream.write(Wire.frame(.interested))
        } else if !wanted && amInterested {
            amInterested = false
            stream.write(Wire.frame(.notInterested))
        }
    }

    // MARK: - Download pipeline

    func requestMore() async {
        guard !isClosed, !peerChoking, await session.hasMetadata,
              !(await session.isComplete) else { return }
        if !amInterested {
            await updateInterest()
            guard amInterested else { return }
        }

        // Grow the pipeline with observed throughput: roughly one second of data.
        pipeline = max(Self.minPipeline,
                       min(Self.maxPipeline, Int(downloadRate / Double(blockSize)) + Self.minPipeline))

        while pending.count < pipeline {
            guard let request = await session.nextRequest(for: key) else { break }
            // Asking is how a leecher controls its own download rate.
            await session.awaitDownloadBudget(request.length)
            guard !isClosed, !peerChoking else { return }
            pending[BlockKey(index: request.index, begin: request.begin)] = request.length
            stream.write(Wire.request(index: request.index, begin: request.begin,
                                      length: request.length))
        }
    }

    /// Cancel outstanding requests for a piece somebody else finished first.
    func dropPending(piece index: Int) {
        for (block, length) in pending where block.index == index {
            pending.removeValue(forKey: block)
            stream.write(Wire.cancel(index: index, begin: block.begin, length: length))
        }
    }

    // MARK: - Upload

    func setChoking(_ choking: Bool) {
        guard choking != amChoking, !isClosed else { return }
        amChoking = choking
        stream.write(Wire.frame(choking ? .choke : .unchoke))
    }

    private func queueUpload(index: Int, begin: Int, length: Int) async throws {
        guard !amChoking, await session.hasMetadata else { return }
        guard length > 0, length <= Self.maxBlockRequest else {
            throw Wire.WireError.malformed("request for \(length) bytes")
        }
        guard await session.canServe(piece: index, begin: begin, length: length) else { return }
        guard uploadQueue.count < Self.maxUploadQueue else { return }  // peer is flooding us
        uploadQueue.append((index, begin, length))
        await serveUploads()
    }

    private func serveUploads() async {
        guard !uploading else { return }
        uploading = true
        defer { uploading = false }
        while !uploadQueue.isEmpty, !isClosed, !amChoking {
            let item = uploadQueue.removeFirst()
            guard let data = await session.readBlock(index: item.index, begin: item.begin,
                                                     length: item.length) else { continue }
            await session.awaitUploadBudget(data.count)
            guard !isClosed, !amChoking else { return }
            stream.write(Wire.piece(index: item.index, begin: item.begin, block: data))
            bytesUploaded += data.count
            await session.accountUpload(data.count)
        }
    }

    // MARK: - Extension protocol

    private func handleExtended(_ payload: Data) async throws {
        guard let extensionID = payload.first else {
            throw Wire.WireError.malformed("empty extended message")
        }
        let body = Data(payload.dropFirst())
        if extensionID == 0 {
            await handleExtendedHandshake(body)
        } else if extensionID == 1 {
            await handleMetadata(body)
        }
    }

    private func handleExtendedHandshake(_ body: Data) async {
        guard let info = try? Bencode.decode(body), info.dictionaryValue != nil else { return }
        if let raw = info["m"]?["ut_metadata"]?.integerValue, raw > 0, raw < 256 {
            utMetadataID = UInt8(raw)
        } else {
            utMetadataID = nil
        }
        if let size = info["metadata_size"]?.integerValue, size > 0, size <= 16 * 1024 * 1024 {
            metadataSize = size
        }
        if let version = info["v"]?.stringValue, !version.isEmpty {
            clientName = String(version.prefix(24))
        }
        if !(await session.hasMetadata) { await requestMetadata() }
    }

    /// Ask for every metadata piece we have not already asked this peer for.
    func requestMetadata() async {
        guard let extensionID = utMetadataID, let size = metadataSize, size > 0 else { return }
        await session.noteMetadataSize(size)
        let count = (size + Wire.metadataPieceSize - 1) / Wire.metadataPieceSize
        for piece in 0..<count {
            guard !requestedMetadataPieces.contains(piece),
                  !(await session.hasMetadataPiece(piece)) else { continue }
            requestedMetadataPieces.insert(piece)
            stream.write(Wire.extended(extensionID, Wire.metadataRequest(piece: piece)))
        }
    }

    private func handleMetadata(_ body: Data) async {
        guard let (header, trailing) = try? Wire.parseMetadata(body),
              let piece = header["piece"]?.integerValue,
              let type = header["msg_type"]?.integerValue else { return }

        switch Wire.MetadataMessage(rawValue: type) {
        case .data:
            if let total = header["total_size"]?.integerValue {
                await session.noteMetadataSize(total)
            }
            await session.metadataPieceArrived(from: describedName, index: piece, data: trailing)

        case .request:
            guard let extensionID = utMetadataID else { return }
            if let chunk = await session.metadataPiece(piece) {
                stream.write(Wire.extended(extensionID,
                                           Wire.metadataData(piece: piece,
                                                             totalSize: await session.metadataSize ?? 0,
                                                             chunk: chunk)))
            } else {
                stream.write(Wire.extended(extensionID, Wire.metadataReject(piece: piece)))
            }

        case .reject:
            requestedMetadataPieces.remove(piece)

        case nil:
            break
        }
    }

    /// Called once the piece manager exists, for both the magnet and the
    /// plain .torrent path.
    func piecesBecameReady() async {
        sendBitfield(await session.currentBitfield())
        await session.registerPeerWithPieces(key)
        if let bits = deferredBitfield {
            await session.peer(key, hasBitfield: bits)
            deferredBitfield = nil
        }
        for index in deferredHave { await session.peer(key, hasPiece: index) }
        deferredHave.removeAll()
        await updateInterest()
        await requestMore()
    }

    // MARK: - Housekeeping

    private func tickLoop() async {
        while !isClosed {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !isClosed else { return }
            let now = Date().timeIntervalSinceReferenceDate
            if now - lastMessageAt > Self.idleTimeout {
                await session.log(peerError: TCPConnection.ConnectionError.timedOut,
                                  from: describedName)
                await close()
                return
            }
            if now - windowStarted >= 1 {
                downloadRate = Double(windowBytes) / (now - windowStarted)
                windowBytes = 0
                windowStarted = now
            }
            stream.write(Wire.frame(nil))    // keep-alive
            await requestMore()
        }
    }
}

/// Run `work`, giving up after `seconds`.
func withTimeout<T: Sendable>(_ seconds: TimeInterval,
                              _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TCPConnection.ConnectionError.timedOut
        }
        guard let result = try await group.next() else {
            throw TCPConnection.ConnectionError.timedOut
        }
        group.cancelAll()
        return result
    }
}
