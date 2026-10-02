import Foundation

struct BittSettings: Codable, Equatable, Sendable {
    var downloadDirectory: String = NSHomeDirectory() + "/Downloads"
    var listenPort = 6881
    var maxPeers = 60
    var seedAfterComplete = true
    /// Bytes per second across every torrent; 0 means unlimited.
    var downloadLimit = 0
    var uploadLimit = 0
    /// Ask the router to forward the listening port (NAT-PMP, then UPnP).
    var mapPortAutomatically = true

    init() {}

    init(downloadDirectory: String, listenPort: Int, maxPeers: Int, seedAfterComplete: Bool,
         downloadLimit: Int, uploadLimit: Int, mapPortAutomatically: Bool) {
        self.downloadDirectory = downloadDirectory
        self.listenPort = listenPort
        self.maxPeers = maxPeers
        self.seedAfterComplete = seedAfterComplete
        self.downloadLimit = downloadLimit
        self.uploadLimit = uploadLimit
        self.mapPortAutomatically = mapPortAutomatically
    }

    /// Decoded field by field so that a settings file written by an older build
    /// — one that predates some of these keys — still loads. The synthesised
    /// decoder would throw on the first missing key and lose the whole file.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = BittSettings()
        downloadDirectory = try container.decodeIfPresent(String.self, forKey: .downloadDirectory)
            ?? fallback.downloadDirectory
        listenPort = try container.decodeIfPresent(Int.self, forKey: .listenPort)
            ?? fallback.listenPort
        maxPeers = try container.decodeIfPresent(Int.self, forKey: .maxPeers) ?? fallback.maxPeers
        seedAfterComplete = try container.decodeIfPresent(Bool.self, forKey: .seedAfterComplete)
            ?? fallback.seedAfterComplete
        downloadLimit = try container.decodeIfPresent(Int.self, forKey: .downloadLimit) ?? 0
        uploadLimit = try container.decodeIfPresent(Int.self, forKey: .uploadLimit) ?? 0
        mapPortAutomatically = try container
            .decodeIfPresent(Bool.self, forKey: .mapPortAutomatically) ?? true
    }
}

struct PeerSnapshot: Sendable, Equatable {
    let address: String
    let client: String
    let downloaded: Int
    let uploaded: Int
    let rate: Double
    let isChoked: Bool
    let isIncoming: Bool
}

struct FileSnapshot: Sendable, Equatable {
    let path: String
    let length: Int
    let done: Int
}

struct DetailsSnapshot: Sendable, Equatable {
    var infoHash = ""
    var name = ""
    var savePath = ""
    var files: [FileSnapshot] = []
    var peers: [PeerSnapshot] = []
    var trackers: [TrackerStatus] = []
    var log: [String] = []
    var pieceCount = 0
    var pieceLength = 0
    var total = 0
    var isPrivate = false
}

/// Just enough about a torrent to ask the user what to do with it, without
/// adding it first.
struct TorrentPreview: Sendable {
    let infoHash: String
    let name: String
    let totalLength: Int
    let fileCount: Int
    let isMagnet: Bool
    let alreadyAdded: Bool
    /// Where peers can be looked for. A magnet with none of these and no DHT
    /// has nowhere to go, which is worth saying before it is added.
    let trackerCount: Int
}

enum ManagerError: LocalizedError {
    case alreadyInList(String)
    case unknownTorrent(String)
    case noSuchFile(String)

    var errorDescription: String? {
        switch self {
        case .alreadyInList(let name): return "already in the list: \(name)"
        case .unknownTorrent(let hash): return "unknown torrent: \(hash)"
        case .noSuchFile(let path): return "no such file: \(path)"
        }
    }
}

/// Looks after every torrent in the app, and remembers them across launches.
actor TorrentManager {
    private struct Entry {
        let infoHash: String
        var source: String          // magnet URI, or a path under torrents/
        let downloadDirectory: URL
        let session: TorrentSession
        var task: Task<Void, Never>?
        var cachedMetadata = false
        var wasComplete = false
        /// Mirrored from the session so the state can be built without awaiting
        /// anything — an await here is what let two saves race each other.
        var isPaused: Bool
        var totalDownloaded: Int
        var totalUploaded: Int
    }

    /// One pair of buckets for the whole app, which is how a user thinks about
    /// "don't use more than 2 MB/s".
    private let limits = RateLimits()
    private let portMapper = PortMapper()

    private let baseDirectory: URL
    private let torrentDirectory: URL
    private let stateURL: URL

    private(set) var settings: BittSettings
    private var entries: [String: Entry] = [:]
    private var listener: PeerListener
    private var ticker: Task<Void, Never>?

    /// Called when a torrent finishes, so the app can show a notification.
    var onFinished: (@Sendable (String, String) -> Void)?

    init(baseDirectory: URL? = nil) {
        let base = baseDirectory ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BITT")
        self.baseDirectory = base
        self.torrentDirectory = base.appendingPathComponent("torrents")
        self.stateURL = base.appendingPathComponent("state.json")
        try? FileManager.default.createDirectory(at: torrentDirectory,
                                                 withIntermediateDirectories: true)
        self.settings = BittSettings()
        self.listener = PeerListener(port: settings.listenPort)
    }

    var listenPort: Int {
        get async { await listener.port }
    }

    func setFinishHandler(_ handler: @escaping @Sendable (String, String) -> Void) {
        onFinished = handler
    }

    // MARK: - Lifecycle

    func start() async {
        loadState()
        await limits.download.setLimit(bytesPerSecond: settings.downloadLimit)
        await limits.upload.setLimit(bytesPerSecond: settings.uploadLimit)
        listener = PeerListener(port: settings.listenPort)
        if await !listener.start() {
            // Not fatal: outgoing connections still work.
        }
        if settings.mapPortAutomatically {
            let port = await listener.port
            Task { await self.portMapper.start(internalPort: port) }
        }
        await restoreTorrents()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await self?.tick()
            }
        }
    }

    var portMappingStatus: PortMapper.Status {
        get async { await portMapper.status }
    }

    func shutdown() async {
        ticker?.cancel()
        await portMapper.stop()
        saveState()
        let sessions = entries.values.map(\.session)
        for entry in entries.values { entry.task?.cancel() }
        await withTaskGroup(of: Void.self) { group in
            for session in sessions {
                group.addTask { await session.shutdown() }
            }
        }
        entries.removeAll()
        await listener.close()
    }

    // MARK: - Adding

    /// Turn a user-supplied string into something a session can be built from.
    private func resolve(_ source: String) async throws -> (TorrentSource, String) {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("magnet:") {
            return (.magnet(try MagnetLink(trimmed)), trimmed)
        }
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            guard let url = URL(string: trimmed) else { throw ManagerError.noSuchFile(trimmed) }
            let (data, _) = try await URLSession.shared.data(from: url)
            return (.torrent(try Metainfo.parse(data)), trimmed)
        }
        var path = trimmed
        if path.hasPrefix("file://") {
            path = URL(string: path)?.path ?? String(path.dropFirst("file://".count))
        }
        guard FileManager.default.fileExists(atPath: path) else {
            throw ManagerError.noSuchFile(path)
        }
        return (.torrent(try Metainfo.parse(contentsOf: URL(fileURLWithPath: path))), path)
    }

    /// Resolve a source far enough to describe it. Does not add anything.
    func preview(_ source: String) async throws -> TorrentPreview {
        let (resolved, _) = try await resolve(source)
        let hash = resolved.infoHash.hexString
        switch resolved {
        case .torrent(let meta):
            return TorrentPreview(infoHash: hash, name: meta.name,
                                  totalLength: meta.totalLength,
                                  fileCount: meta.files.count, isMagnet: false,
                                  alreadyAdded: entries[hash] != nil,
                                  trackerCount: meta.trackers.count)
        case .magnet(let link):
            return TorrentPreview(infoHash: hash,
                                  name: link.displayName.isEmpty ? hash : link.displayName,
                                  totalLength: 0, fileCount: 0, isMagnet: true,
                                  alreadyAdded: entries[hash] != nil,
                                  trackerCount: link.trackers.count + link.peers.count)
        }
    }

    @discardableResult
    func add(_ source: String, downloadDirectory: String? = nil,
             paused: Bool = false, carriedDownloaded: Int = 0,
             carriedUploaded: Int = 0) async throws -> (hash: String, name: String) {
        let (resolved, original) = try await resolve(source)
        let hash = resolved.infoHash.hexString
        if let existing = entries[hash] {
            throw ManagerError.alreadyInList(await existing.session.displayName)
        }

        let target = URL(fileURLWithPath:
            (downloadDirectory ?? settings.downloadDirectory as String) as String)
            .standardizedFileURL
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        var stored = original
        if case .torrent(let meta) = resolved { stored = cacheTorrentFile(meta) }

        let session = TorrentSession(source: resolved,
                                     downloadDirectory: target,
                                     listenPort: settings.listenPort,
                                     maxPeers: settings.maxPeers,
                                     seedAfterComplete: settings.seedAfterComplete,
                                     listener: listener,
                                     stayAlive: true,
                                     paused: paused,
                                     limits: limits,
                                     carriedDownloaded: carriedDownloaded,
                                     carriedUploaded: carriedUploaded)
        var entry = Entry(infoHash: hash, source: stored, downloadDirectory: target,
                          session: session, isPaused: paused,
                          totalDownloaded: carriedDownloaded, totalUploaded: carriedUploaded)
        entry.task = Task { await session.run() }
        entries[hash] = entry
        saveState()
        return (hash, await session.displayName)
    }

    /// Keep our own copy of the .torrent so the list survives a restart.
    private func cacheTorrentFile(_ meta: Metainfo) -> String {
        let target = torrentDirectory.appendingPathComponent(meta.infoHash.hexString + ".torrent")
        if !FileManager.default.fileExists(atPath: target.path) {
            try? meta.torrentFileData().write(to: target)
        }
        return target.path
    }

    // MARK: - Control

    private func entry(_ hash: String) throws -> Entry {
        guard let entry = entries[hash] else { throw ManagerError.unknownTorrent(hash) }
        return entry
    }

    func pause(_ hash: String) async throws {
        try await entry(hash).session.pause()
        entries[hash]?.isPaused = true
        saveState()
    }

    func resume(_ hash: String) async throws {
        try await entry(hash).session.resume()
        entries[hash]?.isPaused = false
        saveState()
    }

    func pauseAll() async {
        for entry in entries.values { await entry.session.pause() }
        for hash in entries.keys { entries[hash]?.isPaused = true }
        saveState()
    }

    func resumeAll() async {
        for entry in entries.values { await entry.session.resume() }
        for hash in entries.keys { entries[hash]?.isPaused = false }
        saveState()
    }

    func remove(_ hash: String, deleteData: Bool) async throws {
        let entry = try self.entry(hash)
        let session = entry.session

        // Close the local side first: the loops have to be stopped and the
        // files closed before the payload can be deleted, or a download still
        // in flight writes them straight back.
        await session.quiesce()
        if deleteData { await session.deletePayload() }

        entry.task?.cancel()
        entries.removeValue(forKey: hash)
        let cached = torrentDirectory.appendingPathComponent(hash + ".torrent")
        try? FileManager.default.removeItem(at: cached)
        saveState()

        // The torrent is gone as far as the user is concerned. Saying goodbye
        // to its trackers is worth doing, but not worth waiting for.
        Task.detached { await session.sayGoodbye() }
    }

    func update(settings newValue: BittSettings) async {
        let previous = settings
        settings = newValue
        if previous.downloadDirectory != newValue.downloadDirectory {
            try? FileManager.default.createDirectory(
                at: URL(fileURLWithPath: newValue.downloadDirectory),
                withIntermediateDirectories: true)
        }
        if previous.seedAfterComplete != newValue.seedAfterComplete {
            for entry in entries.values {
                await entry.session.setSeedAfterComplete(newValue.seedAfterComplete)
            }
        }
        if previous.maxPeers != newValue.maxPeers {
            for entry in entries.values { await entry.session.setMaxPeers(newValue.maxPeers) }
        }
        await limits.download.setLimit(bytesPerSecond: newValue.downloadLimit)
        await limits.upload.setLimit(bytesPerSecond: newValue.uploadLimit)
        if previous.mapPortAutomatically != newValue.mapPortAutomatically {
            if newValue.mapPortAutomatically {
                let port = await listener.port
                Task { await self.portMapper.start(internalPort: port) }
            } else {
                await portMapper.stop()
            }
        }
        saveState()
    }

    // MARK: - Reporting

    func snapshot() async -> [TorrentStatus] {
        var out: [TorrentStatus] = []
        for entry in entries.values {
            out.append(await entry.session.status())
        }
        return out.sorted { $0.addedAt < $1.addedAt }
    }

    func details(_ hash: String) async throws -> DetailsSnapshot {
        let entry = try self.entry(hash)
        let session = entry.session
        var out = DetailsSnapshot()
        out.infoHash = hash
        out.name = await session.displayName
        out.savePath = await session.savePath
        out.log = await session.logLines

        if let meta = await session.meta {
            let done = await session.bytesPerFile()
            out.files = meta.files.enumerated().map { index, file in
                FileSnapshot(path: file.path, length: file.length,
                             done: index < done.count ? done[index] : 0)
            }
            out.pieceCount = meta.pieceCount
            out.pieceLength = meta.pieceLength
            out.total = meta.totalLength
            out.isPrivate = meta.isPrivate
        }

        for peer in await session.currentPeers {
            out.peers.append(PeerSnapshot(address: peer.address.description,
                                          client: await peer.clientName.isEmpty
                                            ? "unknown" : peer.clientName,
                                          downloaded: await peer.bytesDownloaded,
                                          uploaded: await peer.bytesUploaded,
                                          rate: await peer.downloadRate,
                                          isChoked: await peer.peerChoking,
                                          isIncoming: peer.isIncoming))
        }
        out.peers.sort { $0.downloaded > $1.downloaded }
        out.trackers = (await session.status()).trackers
        return out
    }

    func torrentFileData(for hash: String) async -> Data? {
        try? await entry(hash).session.torrentFileData()
    }

    // MARK: - Periodic work

    private var ticks = 0

    private func tick() async {
        ticks += 1
        // The ratio is only as good as the last save, so checkpoint now and then.
        if ticks % 30 == 0 { saveState() }
        for hash in Array(entries.keys) {
            guard var entry = entries[hash] else { continue }

            // Once a magnet resolves, write the .torrent so restarts are instant.
            if !entry.cachedMetadata, let meta = await entry.session.meta {
                if entry.source.hasPrefix("magnet:") { entry.source = cacheTorrentFile(meta) }
                entry.cachedMetadata = true
            }
            let complete = await entry.session.isComplete
            let finishedJustNow = complete && !entry.wasComplete
            entry.wasComplete = complete
            entry.isPaused = await entry.session.isPaused
            entry.totalDownloaded = await entry.session.totalDownloaded
            entry.totalUploaded = await entry.session.totalUploaded

            // Removing a torrent can land on any of those awaits. Writing the
            // entry back blindly would bring it straight back from the dead.
            guard entries[hash] != nil else { continue }
            entries[hash] = entry

            if finishedJustNow {
                onFinished?(await entry.session.displayName, await entry.session.savePath)
                saveState()
            }
        }
    }

    // MARK: - Persistence

    struct StoredState: Codable {
        struct StoredTorrent: Codable {
            let hash: String
            let source: String
            let directory: String
            let paused: Bool
            var downloaded: Int = 0
            var uploaded: Int = 0

            init(hash: String, source: String, directory: String, paused: Bool,
                 downloaded: Int = 0, uploaded: Int = 0) {
                self.hash = hash
                self.source = source
                self.directory = directory
                self.paused = paused
                self.downloaded = downloaded
                self.uploaded = uploaded
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                hash = try container.decode(String.self, forKey: .hash)
                source = try container.decode(String.self, forKey: .source)
                directory = try container.decode(String.self, forKey: .directory)
                paused = try container.decodeIfPresent(Bool.self, forKey: .paused) ?? false
                downloaded = try container.decodeIfPresent(Int.self, forKey: .downloaded) ?? 0
                uploaded = try container.decodeIfPresent(Int.self, forKey: .uploaded) ?? 0
            }
        }
        var version = 2
        var settings = BittSettings()
        var torrents: [StoredTorrent] = []
    }

    /// The first version of BITT kept its state in the Python engine's shape.
    /// Read it so an upgrade does not empty the list.
    struct LegacyState: Codable {
        struct LegacySettings: Codable {
            var download_dir: String?
            var port: Int?
            var max_peers: Int?
            var seed_after_complete: Bool?
        }
        struct LegacyTorrent: Codable {
            var hash: String
            var source: String
            var dir: String?
            var paused: Bool?
        }
        var version: Int?
        var settings: LegacySettings?
        var torrents: [LegacyTorrent]?

        /// Only the Python engine's file had `download_dir` / `dir`. Without one
        /// of those this is some other shape and must not be guessed at.
        var looksGenuine: Bool {
            version == 1 || settings?.download_dir != nil
                || (torrents?.contains { $0.dir != nil } ?? false)
        }

        var converted: StoredState {
            var out = StoredState()
            if let settings {
                out.settings.downloadDirectory =
                    settings.download_dir ?? out.settings.downloadDirectory
                out.settings.listenPort = settings.port ?? out.settings.listenPort
                out.settings.maxPeers = settings.max_peers ?? out.settings.maxPeers
                out.settings.seedAfterComplete =
                    settings.seed_after_complete ?? out.settings.seedAfterComplete
            }
            out.torrents = (torrents ?? []).map {
                .init(hash: $0.hash, source: $0.source,
                      directory: $0.dir ?? out.settings.downloadDirectory,
                      paused: $0.paused ?? false)
            }
            return out
        }
    }

    /// Exposed so the decoding rules can be tested directly: a settings file
    /// that fails to load quietly sends every torrent to the wrong folder.
    static func parseState(_ data: Data) -> StoredState? {
        if let stored = try? JSONDecoder().decode(StoredState.self, from: data) {
            return stored
        }
        if let legacy = try? JSONDecoder().decode(LegacyState.self, from: data),
           legacy.looksGenuine {
            return legacy.converted
        }
        return nil
    }

    private func readState() -> StoredState? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return TorrentManager.parseState(data)
    }

    private func loadState() {
        guard let stored = readState() else { return }
        settings = stored.settings
    }

    private func restoreTorrents() async {
        guard let stored = readState() else { return }
        for item in stored.torrents {
            do {
                try await add(item.source, downloadDirectory: item.directory,
                              paused: item.paused,
                              carriedDownloaded: item.downloaded,
                              carriedUploaded: item.uploaded)
            } catch {
                // A torrent whose file went missing should not stop the rest.
                continue
            }
        }
    }

    /// Built and written synchronously on the actor. It used to run in a
    /// detached task that awaited each session, so two saves could finish out of
    /// order and an older snapshot could land on top of a newer one — bringing
    /// back a torrent that had just been removed. The file is a few kilobytes.
    private func saveState() {
        var stored = StoredState()
        stored.settings = settings
        for entry in entries.values {
            stored.torrents.append(.init(hash: entry.infoHash,
                                         source: entry.source,
                                         directory: entry.downloadDirectory.path,
                                         paused: entry.isPaused,
                                         downloaded: entry.totalDownloaded,
                                         uploaded: entry.totalUploaded))
        }
        stored.torrents.sort { $0.hash < $1.hash }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }
}
