import Combine
import Foundation

/// The UI's view of the torrent engine.
///
/// The engine is Swift and runs inside this process, so this is a thin
/// observable wrapper: it polls the manager once a second and republishes what
/// changed.
@MainActor
final class Engine: ObservableObject {
    @Published private(set) var torrents: [TorrentState] = []
    @Published private(set) var status: EngineStatus = .starting
    @Published private(set) var listenPort: Int = 0
    @Published var settings = EngineSettings()
    @Published var lastMessage: String = ""
    /// What the router said about forwarding our port.
    @Published private(set) var portMapping = "not requested"
    /// Torrents that finished while the app was running, newest first.
    @Published private(set) var recentlyFinished: [(name: String, path: String)] = []

    private let manager = TorrentManager()
    private var poller: Task<Void, Never>?
    private var started = false

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        Task {
            await manager.setFinishHandler { [weak self] name, path in
                Task { @MainActor in self?.torrentFinished(name: name, path: path) }
            }
            await manager.start()
            settings = EngineSettings(await manager.settings)
            listenPort = await manager.listenPort
            status = .running
            poller = Task { [weak self] in await self?.pollLoop() }
        }
    }

    func stop() {
        poller?.cancel()
        poller = nil
        started = false
        // The app is quitting; give the engine a moment to tell the trackers.
        //
        // This has to be a *detached* task. Engine is @MainActor, so a plain
        // Task inherits that isolation and cannot start until the main actor is
        // free — which it never is, because the line below is blocking it. The
        // engine was never actually shut down on quit: the app simply froze for
        // the length of the timeout and then exited. A detached task runs on the
        // cooperative pool and is free to get on with it.
        let manager = self.manager
        let semaphore = DispatchSemaphore(value: 0)
        let started = Date()
        Task.detached {
            await manager.shutdown()
            semaphore.signal()
        }
        let finished = semaphore.wait(timeout: .now() + 3)
        AppLog.write(String(format: "engine stopped in %.2fs%@", -started.timeIntervalSinceNow,
                            finished == .success ? "" : " (gave up waiting)"))
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            let snapshot = await manager.snapshot()
            let mapped = snapshot.map(TorrentState.init)
            if mapped != torrents { torrents = mapped }
            let port = await manager.listenPort
            if port != listenPort { listenPort = port }
            let mapping = await manager.portMappingStatus.summary
            if mapping != portMapping { portMapping = mapping }
            try? await Task.sleep(nanoseconds: 900_000_000)
        }
    }

    private func torrentFinished(name: String, path: String) {
        recentlyFinished.insert((name: name, path: path), at: 0)
        if recentlyFinished.count > 20 { recentlyFinished.removeLast() }
        Notifier.finished(name: name, path: path)
    }

    // MARK: - Commands

    func add(source: String, directory: String? = nil,
             completion: ((Result<String, Error>) -> Void)? = nil) {
        Task {
            do {
                let added = try await manager.add(source, downloadDirectory: directory)
                AppLog.write("added \(source)")
                completion?(.success(added.hash))
            } catch {
                AppLog.write("add failed for \(source): \(error.localizedDescription)")
                lastMessage = error.localizedDescription
                completion?(.failure(error))
            }
        }
    }

    /// Describe a torrent before committing to it, so the user can be asked.
    func preview(source: String) async -> TorrentPreview? {
        try? await manager.preview(source)
    }

    func add(source: String, directory: String?, paused: Bool,
             completion: ((Result<String, Error>) -> Void)? = nil) {
        Task {
            do {
                let added = try await manager.add(source, downloadDirectory: directory,
                                                  paused: paused)
                AppLog.write("added \(source)\(paused ? " (paused)" : "")")
                completion?(.success(added.hash))
            } catch {
                AppLog.write("add failed for \(source): \(error.localizedDescription)")
                lastMessage = error.localizedDescription
                completion?(.failure(error))
            }
        }
    }

    func pause(_ hash: String) { Task { try? await manager.pause(hash) } }
    func resume(_ hash: String) { Task { try? await manager.resume(hash) } }
    func pauseAll() { Task { await manager.pauseAll() } }
    func resumeAll() { Task { await manager.resumeAll() } }

    func remove(_ hash: String, deleteData: Bool) {
        Task { try? await manager.remove(hash, deleteData: deleteData) }
    }

    func apply(settings newValue: EngineSettings) {
        settings = newValue
        Task { await manager.update(settings: newValue.engineValue) }
    }

    func details(for hash: String, completion: @escaping (TorrentDetails?) -> Void) {
        Task {
            guard let snapshot = try? await manager.details(hash) else {
                completion(nil)
                return
            }
            completion(TorrentDetails(snapshot))
        }
    }

    // MARK: - Derived values

    var totalDownloadRate: Double { torrents.reduce(0) { $0 + $1.downloadRate } }
    var totalUploadRate: Double { torrents.reduce(0) { $0 + $1.uploadRate } }
    var activeCount: Int { torrents.filter { !$0.paused && !$0.complete }.count }
    /// True once any torrent has accepted an incoming peer.
    var isConnectable: Bool { torrents.contains { $0.isConnectable } }
    var totalShared: Int64 { torrents.reduce(0) { $0 + $1.totalUploaded } }

    func torrent(_ hash: String?) -> TorrentState? {
        guard let hash else { return nil }
        return torrents.first { $0.hash == hash }
    }
}
