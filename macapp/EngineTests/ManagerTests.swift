import Foundation

enum ManagerTests {
    static func run(fixtures: URL) async {
        Check.section("Torrent list")

        let base = fixtures.appendingPathComponent("manager-store")
        let downloads = fixtures.appendingPathComponent("manager-downloads")
        try? FileManager.default.removeItem(at: base)
        try? FileManager.default.removeItem(at: downloads)
        try? FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)

        let manager = TorrentManager(baseDirectory: base)
        await manager.start()

        let fromFile = try? await manager.add(
            fixtures.appendingPathComponent("sample.torrent").path,
            downloadDirectory: downloads.path)
        _ = try? await manager.add(
            "magnet:?xt=urn:btih:" + String(repeating: "ab", count: 20) + "&dn=Second",
            downloadDirectory: downloads.path)

        await Check.that("both torrents are listed") { await manager.snapshot().count == 2 }

        guard let fromFile else {
            Check.that("the fixture torrent was added") { false }
            await manager.shutdown()
            return
        }
        try? await manager.remove(fromFile.hash, deleteData: true)

        await Check.that("it goes straight away") { await manager.snapshot().count == 1 }

        // The housekeeping tick used to write entries back from a snapshot taken
        // before the removal, so a deleted torrent reappeared a second later.
        try? await Task.sleep(nanoseconds: 2_600_000_000)

        await Check.that("and it stays gone after the housekeeping runs") {
            let names = await manager.snapshot().map(\.infoHash)
            return names.count == 1 && !names.contains(fromFile.hash)
        }

        await removeIsNotHeldUpByADeadTracker(fixtures: fixtures)

        Check.that("the saved state agrees") {
            let data = try Data(contentsOf: base.appendingPathComponent("state.json"))
            guard let state = TorrentManager.parseState(data) else { return false }
            return state.torrents.count == 1
                && !state.torrents.contains { $0.hash == fromFile.hash }
        }

        await Check.that("removing the last one empties the list") {
            guard let remaining = await manager.snapshot().first else { return false }
            try? await manager.remove(remaining.infoHash, deleteData: false)
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            let data = try? Data(contentsOf: base.appendingPathComponent("state.json"))
            let saved = data.flatMap { TorrentManager.parseState($0) }?.torrents.count ?? -1
            return await manager.snapshot().isEmpty && saved == 0
        }

        await manager.shutdown()
    }

    /// Removing a torrent used to wait for every one of its trackers to be told
    /// it had stopped. A tracker that has gone off the air takes 20 seconds over
    /// HTTP to say so, and the user sat watching a spinner for it.
    private static func removeIsNotHeldUpByADeadTracker(fixtures: URL) async {
        let base = fixtures.appendingPathComponent("manager-slow-tracker")
        let downloads = fixtures.appendingPathComponent("manager-slow-downloads")
        try? FileManager.default.removeItem(at: base)
        try? FileManager.default.removeItem(at: downloads)
        try? FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)

        // 192.0.2.0/24 is reserved for documentation and is not routable, so
        // nothing will ever answer on it.
        guard let torrent = retrackered(fixtures.appendingPathComponent("sample.torrent"),
                                        announce: "http://192.0.2.1:9/announce",
                                        writingTo: base.appendingPathComponent("dead.torrent"))
        else {
            Check.that("built a torrent pointing at a dead tracker") { false }
            return
        }

        // A second one, so that quitting still has a session to close after the
        // first has been removed — otherwise the shutdown below measures nothing.
        guard let other = retrackered(fixtures.appendingPathComponent("sample.torrent"),
                                      announce: "http://192.0.2.2:9/announce",
                                      renamedTo: "second",
                                      writingTo: base.appendingPathComponent("dead2.torrent"))
        else {
            Check.that("built a second torrent pointing at a dead tracker") { false }
            return
        }

        let manager = TorrentManager(baseDirectory: base)
        await manager.start()
        guard let added = try? await manager.add(torrent.path, downloadDirectory: downloads.path),
              (try? await manager.add(other.path, downloadDirectory: downloads.path)) != nil else {
            Check.that("the torrents with the dead trackers were added") { false }
            await manager.shutdown()
            return
        }
        await Check.that("both are listed before the timings") {
            await manager.snapshot().count == 2
        }

        let start = Date()
        try? await manager.remove(added.hash, deleteData: true)
        let removeTook = Date().timeIntervalSince(start)

        Check.that("removing does not wait for a tracker that will never answer") {
            removeTook < 2
        }

        // One torrent is still running, and quitting has to close it.
        let quitStart = Date()
        await manager.shutdown()
        let quitTook = Date().timeIntervalSince(quitStart)

        Check.that("nor does quitting") { quitTook < 3 }
    }

    /// Rewrites a torrent's announce URL, so a test can point one at nothing.
    private static func retrackered(_ source: URL, announce: String,
                                    renamedTo newName: String? = nil,
                                    writingTo target: URL) -> URL? {
        guard let data = try? Data(contentsOf: source),
              case .dictionary(var root)? = try? Bencode.decode(data) else { return nil }
        // Renaming the payload changes the info hash, which is what makes it a
        // second torrent rather than the same one twice.
        if let newName, case .dictionary(var info)? = root[Data("info".utf8)] {
            info[Data("name".utf8)] = .string(Data(newName.utf8))
            root[Data("info".utf8)] = .dictionary(info)
        }
        root[Data("announce".utf8)] = .string(Data(announce.utf8))
        root[Data("announce-list".utf8)] = .list([.list([.string(Data(announce.utf8))])])
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard (try? Bencode.dictionary(root).encoded().write(to: target)) != nil else { return nil }
        return target
    }
}
