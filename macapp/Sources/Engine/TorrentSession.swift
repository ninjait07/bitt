import CryptoKit
import Foundation

struct TrackerStatus: Sendable, Equatable {
    let url: String
    let peers: Int
    let error: String
}

struct TorrentStatus: Sendable, Equatable {
    var infoHash = ""
    var name = ""
    var state = "starting"
    var total = 0
    var done = 0
    var progress: Double = 0
    var downloadRate: Double = 0
    var uploadRate: Double = 0
    var peers = 0
    var seeds = 0
    var candidates = 0
    var downloaded = 0
    var uploaded = 0
    /// Counted across every run, which is what a tracker's ratio reflects.
    var totalDownloaded = 0
    var totalUploaded = 0
    var ratio: Double?
    var piecesDone = 0
    var pieceCount = 0
    var isComplete = false
    var isPaused = false
    var hasMetadata = false
    var elapsed: Double = 0
    var downloadDirectory = ""
    var addedAt: Double = 0
    var listenPort = 0
    /// True once a peer has managed to connect to us.
    var isConnectable = false
    var downloadLimit = 0
    var uploadLimit = 0
    var trackers: [TrackerStatus] = []
    var errors: [String] = []
}

/// Everything for one torrent: trackers, peers, pieces and disk.
actor TorrentSession {
    static let clientVersion = "BITT 1.0"
    static let peerIDPrefix = "-BI1000-"

    static let maxUnchoked = 4
    static let chokeInterval: TimeInterval = 10
    static let optimisticInterval: TimeInterval = 30
    static let connectInterval: TimeInterval = 0.25
    static let peerRetryBase: TimeInterval = 60
    static let pieceCacheSize = 8

    // MARK: - Identity and configuration

    let infoHash: Data
    let peerID: Data
    let downloadDirectory: URL
    let addedAt = Date().timeIntervalSince1970

    private(set) var meta: Metainfo?
    private(set) var pieces: PieceManager?
    private var storage: Storage?

    var maxPeers: Int
    var seedAfterComplete: Bool
    private let verifyOnStart: Bool
    private let uploadEnabled: Bool
    /// Keeps the session alive after the download finishes, so a long-lived
    /// client decides when to drop it.
    private let stayAlive: Bool

    private(set) var isPaused: Bool
    private(set) var listenPort: Int
    private let listener: PeerListener?

    private(set) var displayName: String
    private(set) var statusLine = "starting"

    // MARK: - Runtime state

    private var trackers: [Tracker]
    private var peers: [Int: PeerConnection] = [:]
    private var candidates: [PeerAddress] = []
    private var queued: Set<PeerAddress> = []
    private var connecting: Set<PeerAddress> = []
    private var connected: Set<PeerAddress> = []
    private var retryAt: [PeerAddress: TimeInterval] = [:]
    private var failures: [PeerAddress: Int] = [:]

    private var rawMetadata: Data?
    private var declaredMetadataSize: Int?
    private var metadataPieces: [Int: Data] = [:]

    private(set) var downloaded = 0
    private(set) var uploaded = 0
    /// What earlier runs already moved, so the ratio survives a restart.
    private let carriedDownloaded: Int
    private let carriedUploaded: Int
    private(set) var sawIncomingPeer = false
    private let limits: RateLimits
    private(set) var downloadRate: Double = 0
    private(set) var uploadRate: Double = 0
    private var rateSamples: [(at: TimeInterval, down: Int, up: Int)] = []
    private let startedAt = Date().timeIntervalSinceReferenceDate
    private var completedAt: TimeInterval?
    private var announcedComplete = false
    private var errors: [String] = []

    private var pieceCache: [Int: Data] = [:]
    private var pieceCacheOrder: [Int] = []
    private var optimisticPeer: Int?
    private var optimisticSince: TimeInterval = 0

    private var loops: [Task<Void, Never>] = []
    private var running = false
    private var stopped = false
    private var onFinished: (@Sendable () -> Void)?

    // MARK: - Construction

    init(source: TorrentSource, downloadDirectory: URL, listenPort: Int = 6881,
         maxPeers: Int = 60, extraTrackers: [String] = [], extraPeers: [PeerAddress] = [],
         seedAfterComplete: Bool = false, verifyOnStart: Bool = true,
         uploadEnabled: Bool = true, listener: PeerListener? = nil,
         stayAlive: Bool = false, paused: Bool = false,
         limits: RateLimits = RateLimits(),
         carriedDownloaded: Int = 0, carriedUploaded: Int = 0) {
        self.limits = limits
        self.carriedDownloaded = carriedDownloaded
        self.carriedUploaded = carriedUploaded
        self.peerID = TorrentSession.makePeerID()
        self.downloadDirectory = downloadDirectory
        self.listenPort = listenPort
        self.maxPeers = maxPeers
        self.seedAfterComplete = seedAfterComplete
        self.verifyOnStart = verifyOnStart
        self.uploadEnabled = uploadEnabled
        self.listener = listener
        self.stayAlive = stayAlive
        self.isPaused = paused

        var trackerURLs = extraTrackers
        var hinted = extraPeers

        switch source {
        case .torrent(let meta):
            self.meta = meta
            self.infoHash = meta.infoHash
            self.displayName = meta.name
            self.rawMetadata = meta.rawInfo
            self.declaredMetadataSize = meta.rawInfo.count
            trackerURLs = meta.trackers + trackerURLs
        case .magnet(let link):
            self.infoHash = link.infoHash
            self.displayName = link.displayName.isEmpty
                ? link.infoHash.hexString : link.displayName
            trackerURLs = link.trackers + trackerURLs
            hinted += link.peers.compactMap(PeerAddress.init)
        }

        self.trackers = Tracker.build(trackerURLs)
        // Seed the candidate list directly: calling an isolated method from an
        // initialiser is not allowed.
        for address in hinted where address.port > 0 && !address.host.isEmpty {
            if self.queued.insert(address).inserted { self.candidates.append(address) }
        }
    }

    static func makePeerID() -> Data {
        var id = Data(peerIDPrefix.utf8)
        id.append(Data((0..<6).map { _ in UInt8.random(in: 0...255) }).hexString.prefix(12).data(using: .ascii)!)
        return id.prefix(20)
    }

    // MARK: - Accessors used by PeerConnection

    var hasMetadata: Bool { meta != nil }
    /// True once the piece manager exists. Until then anything a peer tells us
    /// about which pieces it holds has nowhere to go.
    var piecesReady: Bool { pieces != nil }
    var metadataSize: Int? { declaredMetadataSize }
    var isComplete: Bool { pieces?.isComplete ?? false }

    func currentBitfield() -> Data? { pieces?.bitfieldData() }

    func noteMetadataSize(_ size: Int) {
        if declaredMetadataSize == nil, size > 0, size <= 16 * 1024 * 1024 {
            declaredMetadataSize = size
        }
    }

    func hasMetadataPiece(_ index: Int) -> Bool {
        rawMetadata != nil || metadataPieces[index] != nil
    }

    func metadataPiece(_ index: Int) -> Data? {
        guard let raw = rawMetadata else { return nil }
        let start = index * Wire.metadataPieceSize
        guard start < raw.count else { return nil }
        let end = min(start + Wire.metadataPieceSize, raw.count)
        return Data(raw[raw.index(raw.startIndex, offsetBy: start)
                        ..< raw.index(raw.startIndex, offsetBy: end)])
    }

    func accountUpload(_ count: Int) { uploaded += count }

    var totalDownloaded: Int { carriedDownloaded + downloaded }
    var totalUploaded: Int { carriedUploaded + uploaded }

    /// Uploaded over downloaded, the number private trackers enforce.
    var ratio: Double? {
        let base = totalDownloaded > 0 ? totalDownloaded : (pieces?.bytesVerified ?? 0)
        guard base > 0 else { return nil }
        return Double(totalUploaded) / Double(base)
    }

    /// Wait until the shared buckets allow these bytes through.
    func awaitUploadBudget(_ count: Int) async { await limits.upload.consume(count) }
    func awaitDownloadBudget(_ count: Int) async { await limits.download.consume(count) }

    func peerIsUseful(_ key: Int) -> Bool { pieces?.peerIsUseful(key) ?? false }

    func releaseRequests(of key: Int) { pieces?.releaseRequests(of: key) }

    func peer(_ key: Int, hasPiece index: Int) { pieces?.peerHasPiece(key, index) }

    func peer(_ key: Int, hasBitfield bits: Data) {
        guard let pieces else { return }
        pieces.peerHasBitfield(key, Wire.indices(inBitfield: bits,
                                                 pieceCount: pieces.meta.pieceCount))
    }

    func registerPeerWithPieces(_ key: Int) { pieces?.addPeer(key) }

    func nextRequest(for key: Int) -> PieceManager.BlockRequest? {
        pieces?.nextRequest(for: key)
    }

    func canServe(piece index: Int, begin: Int, length: Int) -> Bool {
        guard uploadEnabled, let pieces, let meta else { return false }
        guard index >= 0, index < meta.pieceCount, pieces.have[index] else { return false }
        return begin >= 0 && begin + length <= meta.pieceSize(at: index)
    }

    func log(peerError: Error, from name: String) {
        let text = (peerError as? LocalizedError)?.errorDescription
            ?? "\(type(of: peerError))"
        log("\(name): \(text)")
    }

    func log(_ message: String) {
        let stamp = TorrentSession.timeFormatter.string(from: Date())
        errors.append("\(stamp)  \(message)")
        if errors.count > 40 { errors.removeFirst(errors.count - 40) }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    // MARK: - Peer pool

    func addCandidate(_ address: PeerAddress) {
        guard address.port > 0, !address.host.isEmpty else { return }
        guard !queued.contains(address), !connecting.contains(address),
              !connected.contains(address) else { return }
        queued.insert(address)
        candidates.append(address)
    }

    func peerBecameReady(_ peer: PeerConnection) {
        peers[peer.key] = peer
        connected.insert(peer.address)
        connecting.remove(peer.address)
        failures.removeValue(forKey: peer.address)
        pieces?.addPeer(peer.key)
    }

    func peerWentAway(_ peer: PeerConnection) {
        peers.removeValue(forKey: peer.key)
        connected.remove(peer.address)
        pieces?.removePeer(peer.key)
        let count = (failures[peer.address] ?? 0) + 1
        failures[peer.address] = count
        if count <= 4 && !peer.isIncoming {
            retryAt[peer.address] = Date().timeIntervalSinceReferenceDate
                + TorrentSession.peerRetryBase * Double(count)
        }
    }

    private func nextCandidate() -> PeerAddress? {
        let now = Date().timeIntervalSinceReferenceDate
        for (address, when) in retryAt where when <= now {
            retryAt.removeValue(forKey: address)
            addCandidate(address)
        }
        while !candidates.isEmpty {
            let address = candidates.removeFirst()
            queued.remove(address)
            if connecting.contains(address) || connected.contains(address) { continue }
            return address
        }
        return nil
    }

    func adoptIncoming(stream: TCPConnection, handshake: Wire.Handshake) async {
        guard !isPaused, !stopped, handshake.peerID != peerID,
              peers.count < maxPeers + 10 else {
            stream.cancel()
            return
        }
        // Somebody reached us, so the listening port is open to the world.
        sawIncomingPeer = true
        let peer = PeerConnection(session: self, stream: stream, incoming: true)
        await peer.adopt(handshake: handshake)
        Task { await peer.run() }
    }

    // MARK: - Metadata (magnet)

    func metadataPieceArrived(from peerName: String, index: Int, data: Data) async {
        guard rawMetadata == nil, let size = declaredMetadataSize else { return }
        let count = (size + Wire.metadataPieceSize - 1) / Wire.metadataPieceSize
        guard index >= 0, index < count else { return }
        let expected = index == count - 1
            ? size - index * Wire.metadataPieceSize
            : Wire.metadataPieceSize
        guard data.count == expected else { return }

        metadataPieces[index] = data
        guard metadataPieces.count == count else { return }

        var assembled = Data()
        for piece in 0..<count { assembled.append(metadataPieces[piece]!) }
        guard Data(Insecure.SHA1.hash(data: assembled)) == infoHash else {
            log("metadata failed its hash check; starting over")
            metadataPieces.removeAll()
            return
        }
        do {
            let built = try Metainfo(rawInfo: assembled, trackers: trackers.map(\.url))
            rawMetadata = assembled
            meta = built
            displayName = built.name
            log("got metadata for \(built.name) from \(peerName)")
            await prepareStorage()
        } catch {
            log("metadata is unusable: \(error.localizedDescription)")
            metadataPieces.removeAll()
        }
    }

    // MARK: - Storage

    private func prepareStorage() async {
        guard let meta else { return }
        let store = Storage(meta: meta, downloadDirectory: downloadDirectory)
        storage = store

        // Ask before allocating: allocate() creates every file at its final
        // size, after which "is there data on disk" is always true and a brand
        // new torrent would be hashed from end to end for nothing.
        let worthVerifying = verifyOnStart && store.hasDataOnDisk

        do {
            try await onDisk { try store.allocate() }
        } catch {
            log("could not create the files: \(error.localizedDescription)")
        }

        var have: [Bool]?
        if worthVerifying {
            statusLine = "checking existing files"
            have = await onDiskValue { store.verify() }
            if let have, have.contains(true) {
                log("resuming: \(have.filter { $0 }.count) of \(meta.pieceCount) pieces already on disk")
            }
        }

        let manager = PieceManager(meta: meta, have: have)
        pieces = manager
        statusLine = isPaused ? "paused" : "downloading"
        // Peers that connected while this was being set up had their bitfields
        // dropped on the floor, so let them say it again.
        for peer in peers.values { await peer.piecesBecameReady() }
        if manager.isComplete { await downloadFinished() }
    }

    /// Read a block for upload, caching whole pieces to keep the disk quiet.
    func readBlock(index: Int, begin: Int, length: Int) async -> Data? {
        guard uploadEnabled, let storage, let pieces, pieces.have[index] else { return nil }
        var piece = pieceCache[index]
        if piece == nil {
            do {
                piece = try await onDisk { try storage.readPiece(index) }
            } catch {
                log("read error on piece \(index): \(error.localizedDescription)")
                return nil
            }
            pieceCache[index] = piece
            pieceCacheOrder.append(index)
            while pieceCacheOrder.count > TorrentSession.pieceCacheSize {
                pieceCache.removeValue(forKey: pieceCacheOrder.removeFirst())
            }
        }
        guard let piece, begin + length <= piece.count else { return nil }
        return Data(piece[piece.index(piece.startIndex, offsetBy: begin)
                          ..< piece.index(piece.startIndex, offsetBy: begin + length)])
    }

    // MARK: - Block and piece flow

    func blockArrived(from peer: PeerConnection, index: Int, begin: Int, block: Data) async {
        downloaded += block.count
        guard let pieces else { return }
        let (completed, pieceData) = pieces.blockReceived(from: peer.key, index: index,
                                                          begin: begin, data: block)
        guard completed else { return }
        guard let pieceData else {
            log("piece \(index) failed its hash check; will retry")
            return
        }
        await store(piece: index, data: pieceData)
    }

    private func store(piece index: Int, data: Data) async {
        guard let storage, let pieces else { return }
        do {
            try await onDisk { try storage.writePiece(index, data: data) }
        } catch {
            log("write error on piece \(index): \(error.localizedDescription)")
            pieces.markMissing(index)
            return
        }

        let announcement = Wire.have(index)
        for peer in peers.values {
            await peer.send(raw: announcement)
            await peer.dropPending(piece: index)
            await peer.requestMore()
        }

        if pieces.isComplete { await downloadFinished() }
    }

    private func downloadFinished() async {
        guard completedAt == nil else { return }
        completedAt = Date().timeIntervalSinceReferenceDate
        statusLine = seedAfterComplete ? "seeding" : "complete"
        if !announcedComplete {
            announcedComplete = true
            await announceAll(event: .completed)
        }
        if let storage { await onDiskVoid { storage.flush() } }
        if !seedAfterComplete {
            if stayAlive {
                await pause(status: "finished")
            } else {
                stop()
            }
        }
    }

    // MARK: - Trackers

    private var bytesLeft: Int {
        guard let meta, let pieces else { return 0 }
        return max(0, meta.totalLength - pieces.bytesVerified)
    }

    private func announce(_ tracker: Tracker, event: TrackerEvent = .none) async {
        let request = Tracker.AnnounceRequest(
            infoHash: infoHash, peerID: peerID, port: listenPort,
            uploaded: uploaded, downloaded: downloaded, left: bytesLeft, event: event)
        do {
            let response = try await tracker.announce(request)
            announcedToTrackers = true
            tracker.noteSuccess(response)
            for address in response.peers { addCandidate(address) }
            if !response.warning.isEmpty {
                log("tracker \(tracker.url): \(response.warning)")
            }
        } catch {
            tracker.noteFailure(error)
            log("tracker \(tracker.url): \(tracker.lastError)")
        }
    }

    private func announceAll(event: TrackerEvent) async {
        guard !trackers.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for tracker in trackers {
                group.addTask { await self.announce(tracker, event: event) }
            }
        }
    }

    // MARK: - Choking

    func considerUnchoking(_ peer: PeerConnection) async {
        guard uploadEnabled else { return }
        var unchoked = 0
        for other in peers.values where !(await other.amChoking) { unchoked += 1 }
        if unchoked < TorrentSession.maxUnchoked { await peer.setChoking(false) }
    }

    private func rechoke() async {
        guard uploadEnabled else { return }
        var interested: [(peer: PeerConnection, score: Double)] = []
        for peer in peers.values {
            guard await peer.peerInterested, await !peer.isClosed else { continue }
            let score = completedAt != nil
                ? Double(await peer.bytesUploaded)    // seeding: favour who takes data fastest
                : await peer.downloadRate             // leeching: reciprocate
            interested.append((peer, score))
        }
        interested.sort { $0.score > $1.score }

        var keep = Set(interested.prefix(TorrentSession.maxUnchoked).map(\.peer.key))
        let now = Date().timeIntervalSinceReferenceDate
        if !keep.contains(optimisticPeer ?? -1),
           now - optimisticSince >= TorrentSession.optimisticInterval {
            optimisticPeer = interested.dropFirst(TorrentSession.maxUnchoked)
                .randomElement()?.peer.key
            optimisticSince = now
        }
        if let optimisticPeer { keep.insert(optimisticPeer) }

        for peer in peers.values {
            await peer.setChoking(!keep.contains(peer.key))
        }
    }

    // MARK: - Lifecycle

    func run(onFinished: (@Sendable () -> Void)? = nil) async {
        guard !running else { return }
        running = true
        self.onFinished = onFinished

        if let listener {
            await listener.register(self, infoHash: infoHash)
            listenPort = await listener.port
        } else {
            let own = PeerListener(port: listenPort)
            if await own.start() {
                await own.register(self, infoHash: infoHash)
                listenPort = await own.port
                ownListener = own
            } else {
                log("could not open a listening port; downloads still work")
                listenPort = 0
            }
        }

        if meta != nil {
            await prepareStorage()
        } else {
            statusLine = isPaused ? "paused" : "fetching metadata from peers"
        }

        loops = [
            Task { await self.trackerLoop() },
            Task { await self.connectLoop() },
            Task { await self.chokeLoop() },
            Task { await self.statsLoop() },
        ]
    }

    private var ownListener: PeerListener?

    private func trackerLoop() async {
        if !isPaused { await announceAll(event: .started) }
        while !stopped {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !stopped, !isPaused else { continue }
            let due = trackers.filter(\.isDue)
            guard !due.isEmpty else { continue }
            await withTaskGroup(of: Void.self) { group in
                for tracker in due { group.addTask { await self.announce(tracker) } }
            }
        }
    }

    private func connectLoop() async {
        while !stopped {
            try? await Task.sleep(nanoseconds: UInt64(TorrentSession.connectInterval * 1_000_000_000))
            guard !stopped, !isPaused else { continue }
            while peers.count + connecting.count < maxPeers {
                guard let address = nextCandidate() else { break }
                connecting.insert(address)
                Task { await self.dial(address) }
            }
        }
    }

    private func dial(_ address: PeerAddress) async {
        let stream = TCPConnection(host: address.host, port: address.port)
        let peer = PeerConnection(session: self, stream: stream, incoming: false)
        defer { connecting.remove(address) }
        await peer.run()
    }

    /// A dialled peer stops being "connecting" the moment it is connected,
    /// otherwise it is counted twice against the peer limit for its whole life.
    func dialSucceeded(_ address: PeerAddress) { connecting.remove(address) }

    private func chokeLoop() async {
        while !stopped {
            try? await Task.sleep(nanoseconds: UInt64(TorrentSession.chokeInterval * 1_000_000_000))
            guard !stopped, !isPaused else { continue }
            await rechoke()
        }
    }

    private func statsLoop() async {
        while !stopped {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !stopped else { return }
            let now = Date().timeIntervalSinceReferenceDate
            rateSamples.append((now, downloaded, uploaded))
            if rateSamples.count > 12 { rateSamples.removeFirst() }
            if let first = rateSamples.first, now - first.at > 0 {
                downloadRate = Double(downloaded - first.down) / (now - first.at)
                uploadRate = Double(uploaded - first.up) / (now - first.at)
            }
            pieces?.expireRequests()
            for peer in peers.values { await peer.requestMore() }
        }
    }

    // MARK: - Control

    func pause(status: String = "paused") async {
        guard !isPaused else { return }
        isPaused = true
        statusLine = status
        await announceAll(event: .stopped)
        for peer in peers.values { await peer.close() }
        candidates.removeAll()
        queued.removeAll()
    }

    func resume() async {
        guard isPaused else { return }
        isPaused = false
        if meta == nil {
            statusLine = "fetching metadata from peers"
        } else if completedAt != nil {
            statusLine = seedAfterComplete ? "seeding" : "finished"
        } else {
            statusLine = "downloading"
        }
        await announceAll(event: .started)
    }

    private var saidGoodbye = false
    /// Whether a tracker has ever acknowledged this torrent.
    private var announcedToTrackers = false

    nonisolated func stop() {
        Task { await self.shutdown() }
    }

    func shutdown() async {
        await quiesce()
        await sayGoodbye()
    }

    /// Everything local: stop the loops, drop the peers, flush and close the
    /// files. All of it is quick, none of it touches the network, and it leaves
    /// the torrent in a state where its payload can safely be deleted.
    func quiesce() async {
        guard !stopped else { return }
        stopped = true
        loops.forEach { $0.cancel() }
        loops.removeAll()
        for peer in peers.values { await peer.close() }
        if let listener { await listener.unregister(infoHash: infoHash) }
        if let ownListener { await ownListener.close() }
        if let storage { await onDiskVoid { storage.close() } }
        onFinished?()
    }

    /// Telling the trackers we are leaving is a courtesy to the swarm, not
    /// something the user should have to watch. A tracker that has gone away
    /// takes 20 seconds over HTTP and 8 over UDP to admit it, which is how
    /// Remove and Quit came to sit there spinning. The goodbye now gets a
    /// deadline of its own and whatever has not been sent by then is dropped.
    func sayGoodbye() async {
        // A torrent that never told a tracker it was here has nothing to take
        // back. Most of a paused list is in exactly that position, and quitting
        // should not stop to send announcements that mean nothing.
        guard announcedToTrackers else { return }
        guard !saidGoodbye, !trackers.isEmpty else { return }
        saidGoodbye = true
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.announceAll(event: .stopped) }
            group.addTask {
                try? await Task.sleep(nanoseconds: TorrentSession.goodbyeDeadline)
            }
            await group.next()
            group.cancelAll()
        }
    }

    /// Long enough for a tracker that is still there to answer, short enough
    /// that one that is not costs nothing worth noticing. A tracker that never
    /// hears the goodbye simply keeps us listed until its interval runs out.
    private static let goodbyeDeadline: UInt64 = 500_000_000

    func setSeedAfterComplete(_ value: Bool) { seedAfterComplete = value }
    func setMaxPeers(_ value: Int) { maxPeers = value }

    // MARK: - Status

    func status() async -> TorrentStatus {
        var out = TorrentStatus()
        out.infoHash = infoHash.hexString
        out.name = displayName
        out.state = statusLine
        out.total = meta?.totalLength ?? 0
        out.done = pieces?.bytesVerified ?? 0
        out.progress = out.total > 0 ? Double(out.done) / Double(out.total) : 0
        out.downloadRate = downloadRate
        out.uploadRate = uploadRate
        out.peers = peers.count
        if let pieces {
            var seeds = 0
            for peer in peers.values
            where pieces.pieces(of: peer.key).count == pieces.meta.pieceCount { seeds += 1 }
            out.seeds = seeds
        }
        out.candidates = candidates.count + retryAt.count
        out.downloaded = downloaded
        out.uploaded = uploaded
        out.totalDownloaded = totalDownloaded
        out.totalUploaded = totalUploaded
        out.ratio = ratio
        out.piecesDone = pieces?.piecesDone ?? 0
        out.pieceCount = meta?.pieceCount ?? 0
        out.isComplete = completedAt != nil
        out.isPaused = isPaused
        out.hasMetadata = meta != nil
        out.elapsed = Date().timeIntervalSinceReferenceDate - startedAt
        out.downloadDirectory = downloadDirectory.path
        out.addedAt = addedAt
        out.listenPort = listenPort
        out.isConnectable = sawIncomingPeer
        out.downloadLimit = await limits.download.limit
        out.uploadLimit = await limits.upload.limit
        out.trackers = trackers.map {
            TrackerStatus(url: $0.url, peers: $0.lastPeerCount, error: $0.lastError)
        }
        out.errors = errors
        return out
    }

    var savePath: String { storage?.root.path ?? downloadDirectory.path }
    var currentPeers: [PeerConnection] { Array(peers.values) }
    var trackerList: [Tracker] { trackers }
    var logLines: [String] { errors }

    /// How much of each file is covered by verified pieces.
    func bytesPerFile() -> [Int] {
        guard let meta, let pieces else { return [] }
        var totals = [Int](repeating: 0, count: meta.files.count)
        for (index, owned) in pieces.have.enumerated() where owned {
            let start = index * meta.pieceLength
            let end = start + meta.pieceSize(at: index)
            for (position, entry) in meta.files.enumerated() {
                let overlap = min(end, entry.offset + entry.length) - max(start, entry.offset)
                if overlap > 0 { totals[position] += overlap }
            }
        }
        return totals
    }

    func deletePayload() {
        guard let meta, let storage else { return }
        let manager = FileManager.default
        if meta.isMultiFile {
            let root = storage.root
            if root.deletingLastPathComponent().path == storage.downloadDirectory.path {
                try? manager.removeItem(at: root)
            }
        } else {
            for entry in meta.files {
                if let target = try? storage.url(for: entry.path) {
                    try? manager.removeItem(at: target)
                }
            }
        }
    }

    func torrentFileData() -> Data? { meta?.torrentFileData() }
}

/// What a session was started from.
enum TorrentSource {
    case torrent(Metainfo)
    case magnet(MagnetLink)

    var infoHash: Data {
        switch self {
        case .torrent(let meta): return meta.infoHash
        case .magnet(let link): return link.infoHash
        }
    }
}

// MARK: - Disk hop

private let diskQueue = DispatchQueue(label: "bitt.disk", qos: .utility,
                                      attributes: .concurrent)

func onDisk<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        diskQueue.async { continuation.resume(with: Result { try body() }) }
    }
}

func onDiskValue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        diskQueue.async { continuation.resume(returning: body()) }
    }
}

func onDiskVoid(_ body: @escaping @Sendable () -> Void) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        diskQueue.async { body(); continuation.resume() }
    }
}

extension Storage: @unchecked Sendable {}
