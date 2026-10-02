import Foundation

/// One torrent as the UI sees it, built from the engine's snapshot.
struct TorrentState: Identifiable, Hashable {
    var id: String { hash }

    let hash: String
    let name: String
    let state: String
    let total: Int64
    let done: Int64
    let progress: Double
    let downloadRate: Double
    let uploadRate: Double
    let peers: Int
    let seeds: Int
    let candidates: Int
    let downloaded: Int64
    let uploaded: Int64
    /// Counted across every run — this is what a tracker's ratio reflects.
    let totalDownloaded: Int64
    let totalUploaded: Int64
    let ratio: Double?
    let isConnectable: Bool
    let piecesDone: Int
    let pieceCount: Int
    let complete: Bool
    let paused: Bool
    let downloadDir: String
    let hasMetadata: Bool
    let elapsed: Double

    init(_ status: TorrentStatus) {
        hash = status.infoHash
        name = status.name
        state = status.state
        total = Int64(status.total)
        done = Int64(status.done)
        progress = status.progress
        downloadRate = status.downloadRate
        uploadRate = status.uploadRate
        peers = status.peers
        seeds = status.seeds
        candidates = status.candidates
        downloaded = Int64(status.downloaded)
        uploaded = Int64(status.uploaded)
        totalDownloaded = Int64(status.totalDownloaded)
        totalUploaded = Int64(status.totalUploaded)
        ratio = status.ratio
        isConnectable = status.isConnectable
        piecesDone = status.piecesDone
        pieceCount = status.pieceCount
        complete = status.isComplete
        paused = status.isPaused
        downloadDir = status.downloadDirectory
        hasMetadata = status.hasMetadata
        elapsed = status.elapsed
    }

    /// Seconds remaining, or nil when there is nothing meaningful to predict.
    var eta: TimeInterval? {
        guard !paused, !complete, downloadRate > 1024, total > done else { return nil }
        return Double(total - done) / downloadRate
    }

    var activity: Activity {
        if paused && complete { return .finished }
        if paused { return .paused }
        if complete { return state == "seeding" ? .seeding : .finished }
        if !hasMetadata { return .metadata }
        return .downloading
    }

    enum Activity: String {
        case downloading, seeding, paused, finished, metadata

        var symbol: String {
            switch self {
            case .downloading: return "arrow.down.circle.fill"
            case .seeding: return "arrow.up.circle.fill"
            case .paused: return "pause.circle.fill"
            case .finished: return "checkmark.circle.fill"
            case .metadata: return "magnifyingglass.circle.fill"
            }
        }

        var label: String {
            switch self {
            case .downloading: return "Downloading"
            case .seeding: return "Seeding"
            case .paused: return "Paused"
            case .finished: return "Finished, not sharing"
            case .metadata: return "Finding metadata"
            }
        }
    }
}

struct TorrentDetails {
    struct FileEntry: Identifiable {
        var id: String { path }
        let path: String
        let length: Int64
        let done: Int64
        var fraction: Double { length > 0 ? Double(done) / Double(length) : 1 }
    }

    struct PeerEntry: Identifiable {
        var id: String { address }
        let address: String
        let client: String
        let downloaded: Int64
        let uploaded: Int64
        let rate: Double
        let choked: Bool
        let incoming: Bool
    }

    struct TrackerEntry: Identifiable {
        var id: String { url }
        let url: String
        let peers: Int
        let error: String
    }

    let hash: String
    let name: String
    let savePath: String
    let files: [FileEntry]
    let peers: [PeerEntry]
    let trackers: [TrackerEntry]
    let log: [String]
    let pieceCount: Int
    let pieceLength: Int64
    let total: Int64
    let isPrivate: Bool

    init(_ snapshot: DetailsSnapshot) {
        hash = snapshot.infoHash
        name = snapshot.name
        savePath = snapshot.savePath
        files = snapshot.files.map {
            FileEntry(path: $0.path, length: Int64($0.length), done: Int64($0.done))
        }
        peers = snapshot.peers.map {
            PeerEntry(address: $0.address, client: $0.client,
                      downloaded: Int64($0.downloaded), uploaded: Int64($0.uploaded),
                      rate: $0.rate, choked: $0.isChoked, incoming: $0.isIncoming)
        }
        trackers = snapshot.trackers.map {
            TrackerEntry(url: $0.url, peers: $0.peers, error: $0.error)
        }
        log = snapshot.log
        pieceCount = snapshot.pieceCount
        pieceLength = Int64(snapshot.pieceLength)
        total = Int64(snapshot.total)
        isPrivate = snapshot.isPrivate
    }
}

struct EngineSettings: Equatable {
    var downloadDir: String = NSHomeDirectory() + "/Downloads"
    var port: Int = 6881
    var maxPeers: Int = 60
    var seedAfterComplete: Bool = true
    /// Bytes per second; 0 means unlimited.
    var downloadLimit: Int = 0
    var uploadLimit: Int = 0
    var mapPortAutomatically: Bool = true

    init() {}

    init(_ settings: BittSettings) {
        downloadDir = settings.downloadDirectory
        port = settings.listenPort
        maxPeers = settings.maxPeers
        seedAfterComplete = settings.seedAfterComplete
        downloadLimit = settings.downloadLimit
        uploadLimit = settings.uploadLimit
        mapPortAutomatically = settings.mapPortAutomatically
    }

    var engineValue: BittSettings {
        BittSettings(downloadDirectory: downloadDir, listenPort: port,
                      maxPeers: maxPeers, seedAfterComplete: seedAfterComplete,
                      downloadLimit: downloadLimit, uploadLimit: uploadLimit,
                      mapPortAutomatically: mapPortAutomatically)
    }

    /// The UI talks in MB/s; the engine counts bytes.
    static func megabytes(fromBytes bytes: Int) -> Double {
        bytes <= 0 ? 0 : (Double(bytes) / 1_048_576 * 10).rounded() / 10
    }

    static func bytes(fromMegabytes megabytes: Double) -> Int {
        megabytes <= 0 ? 0 : Int(megabytes * 1_048_576)
    }
}

enum EngineStatus: Equatable {
    case starting
    case running
    case failed(String)
}
