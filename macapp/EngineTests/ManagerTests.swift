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
}
