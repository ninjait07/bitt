import Foundation

enum TransferTests {
    /// Wait until `condition` holds, or give up.
    static func wait(seconds: Double, for condition: @Sendable () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return false
    }

    static func digest(of directory: URL) -> [String: Int] {
        var out: [String: Int] = [:]
        let manager = FileManager.default
        guard let walker = manager.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return out
        }
        for case let url as URL in walker where (try? Data(contentsOf: url)) != nil {
            let relative = url.path.replacingOccurrences(of: directory.path + "/", with: "")
            out[relative] = (try? Data(contentsOf: url))?.hashValue ?? 0
        }
        return out
    }

    static func run(fixtures: URL) async {
        Check.section("Transfer over a real socket")

        guard let meta = try? Metainfo.parse(
            contentsOf: fixtures.appendingPathComponent("sample.torrent")) else {
            Check.that("fixture torrent loads") { false }
            return
        }

        let seedPort = Int.random(in: 39000...39900)
        let seeder = TorrentSession(source: .torrent(meta),
                                    downloadDirectory: fixtures,
                                    listenPort: seedPort,
                                    seedAfterComplete: true,
                                    stayAlive: true)
        await seeder.run()

        let seederReady = await wait(seconds: 20) { await seeder.isComplete }
        await Check.that("seeder verified the payload already on disk") { seederReady }

        let leechDirectory = fixtures.appendingPathComponent("leech")
        try? FileManager.default.removeItem(at: leechDirectory)
        try? FileManager.default.createDirectory(at: leechDirectory, withIntermediateDirectories: true)

        // A magnet with a direct peer hint: this exercises metadata exchange as
        // well as the transfer itself.
        let magnet = try! MagnetLink(
            "magnet:?xt=urn:btih:\(meta.infoHash.hexString)&dn=payload&x.pe=127.0.0.1:\(seedPort)")
        let leecher = TorrentSession(source: .magnet(magnet),
                                     downloadDirectory: leechDirectory,
                                     listenPort: seedPort + 1,
                                     stayAlive: true)
        await leecher.run()

        let gotMetadata = await wait(seconds: 25) { await leecher.hasMetadata }
        await Check.that("leecher fetched the metadata from the peer") { gotMetadata }

        let finished = await wait(seconds: 60) { await leecher.isComplete }
        await Check.that("leecher completed the download") { finished }

        let status = await leecher.status()
        Check.equal("downloaded the whole payload", status.done, meta.totalLength)
        await Check.that("no piece failed its hash") {
            await leecher.pieces?.hashFailures == 0
        }
        await Check.that("seeder uploaded something") {
            await seeder.uploaded > 0
        }

        Check.that("files on disk match the originals byte for byte") {
            let source = fixtures.appendingPathComponent("payload")
            let copy = leechDirectory.appendingPathComponent(meta.name)
            return meta.files.allSatisfy { entry in
                let original = try? Data(contentsOf: source.appendingPathComponent(entry.path))
                let received = try? Data(contentsOf: copy.appendingPathComponent(entry.path))
                return original != nil && original == received
            }
        }

        await leecher.shutdown()
        await seeder.shutdown()
    }

    /// A leecher that already has part of the payload has to hash-check it
    /// first, so its piece manager appears only after peers have connected and
    /// sent their bitfields. Those bitfields used to be dropped, leaving the
    /// torrent stuck at its starting point with peers attached and nothing
    /// moving.
    static func resumeWhilePeersWait(fixtures: URL) async {
        Check.section("Resume with peers already connected")

        guard let meta = try? Metainfo.parse(
            contentsOf: fixtures.appendingPathComponent("sample.torrent")) else { return }

        let seedPort = Int.random(in: 38000...38900)
        let seeder = TorrentSession(source: .torrent(meta),
                                    downloadDirectory: fixtures,
                                    listenPort: seedPort,
                                    seedAfterComplete: true,
                                    stayAlive: true)
        await seeder.run()
        _ = await wait(seconds: 20) { await seeder.isComplete }

        // Copy the payload, then damage the tail of the first file so some of
        // it has to come over the wire.
        let target = fixtures.appendingPathComponent("resume")
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let source = fixtures.appendingPathComponent("payload")
        try? FileManager.default.copyItem(at: source,
                                          to: target.appendingPathComponent(meta.name))

        let damaged = target.appendingPathComponent(meta.name)
            .appendingPathComponent(meta.files[0].path)
        if let handle = try? FileHandle(forUpdating: damaged) {
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size / 2)
            try? handle.write(contentsOf: Data(count: Int(size - size / 2)))
            try? handle.close()
        }

        let leecher = TorrentSession(source: .torrent(meta),
                                     downloadDirectory: target,
                                     listenPort: seedPort + 1,
                                     extraPeers: [PeerAddress(host: "127.0.0.1", port: seedPort)],
                                     stayAlive: true)
        await leecher.run()

        await Check.that("repaired the damaged half") {
            await wait(seconds: 60) { await leecher.isComplete }
        }
        await Check.that("the peer's bitfield was not lost") {
            // A dropped bitfield makes the peer look empty, so nothing is ever
            // requested from it and this stays at zero for ever. Availability
            // itself cannot be checked afterwards: finishing closes the peers,
            // which takes their pieces back out of the count.
            await leecher.downloaded > 0
        }
        await Check.that("only the damaged part came over the wire") {
            await leecher.downloaded < meta.totalLength
        }
        Check.that("files match the originals") {
            let copy = target.appendingPathComponent(meta.name)
            return meta.files.allSatisfy { entry in
                let original = try? Data(contentsOf: source.appendingPathComponent(entry.path))
                let received = try? Data(contentsOf: copy.appendingPathComponent(entry.path))
                return original != nil && original == received
            }
        }

        await leecher.shutdown()
        await seeder.shutdown()
    }

    /// Downloads from whatever is listening on `port`, which the shell script
    /// points at a seeding Python engine.
    static func crossCheck(fixtures: URL, pythonSeedPort: Int) async {
        Check.section("Swift leecher against the Python seeder")

        guard let meta = try? Metainfo.parse(
            contentsOf: fixtures.appendingPathComponent("sample.torrent")) else { return }

        let target = fixtures.appendingPathComponent("from-python")
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        let magnet = try! MagnetLink(
            "magnet:?xt=urn:btih:\(meta.infoHash.hexString)&dn=payload"
            + "&x.pe=127.0.0.1:\(pythonSeedPort)")
        let leecher = TorrentSession(source: .magnet(magnet),
                                     downloadDirectory: target,
                                     listenPort: pythonSeedPort + 500,
                                     stayAlive: true)
        await leecher.run()

        await Check.that("fetched the metadata from the Python peer") {
            await wait(seconds: 25) { await leecher.hasMetadata }
        }
        await Check.that("completed the download from the Python peer") {
            await wait(seconds: 60) { await leecher.isComplete }
        }
        Check.that("bytes match the originals") {
            let source = fixtures.appendingPathComponent("payload")
            let copy = target.appendingPathComponent(meta.name)
            return meta.files.allSatisfy { entry in
                let original = try? Data(contentsOf: source.appendingPathComponent(entry.path))
                let received = try? Data(contentsOf: copy.appendingPathComponent(entry.path))
                return original != nil && original == received
            }
        }

        await leecher.shutdown()
    }
}
