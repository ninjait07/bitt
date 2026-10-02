import Foundation

/// The rename from Swarm to BITT carries the old list across, once. Getting the
/// "once" wrong is how removed torrents came back: the old check asked whether
/// BITT's list was empty, and a list you have emptied yourself looks exactly
/// like a list that was never created.
enum MigrationTests {
    static func run() {
        Check.section("Migration from Swarm")

        let quiet: (String) -> Void = { _ in }

        // A genuine first launch under the new name.
        do {
            let support = sandbox()
            writeList(swarmState(support), hashes: ["aaaa", "bbbb"])

            Check.that("a fresh rename carries the old list over") {
                Migration.carryState(in: support, log: quiet)
            }
            Check.equal("both torrents arrive", listed(bittState(support)), ["aaaa", "bbbb"])
        }

        // The bug, exactly as it was reported: empty the list, then relaunch.
        do {
            let support = sandbox()
            writeList(swarmState(support), hashes: ["aaaa", "bbbb"])
            Migration.carryState(in: support, log: quiet)

            // The user removes every torrent, so BITT saves an empty list.
            writeList(bittState(support), hashes: [])

            Check.that("a second launch carries nothing") {
                !Migration.carryState(in: support, log: quiet)
            }
            Check.that("the torrents you removed stay removed") {
                listed(bittState(support)).isEmpty
            }
        }

        // Removing some, not all, must not resurrect the rest either.
        do {
            let support = sandbox()
            writeList(swarmState(support), hashes: ["aaaa", "bbbb", "cccc"])
            Migration.carryState(in: support, log: quiet)

            writeList(bittState(support), hashes: ["bbbb"])
            Migration.carryState(in: support, log: quiet)
            Check.equal("the two that were removed do not come back",
                        listed(bittState(support)), ["bbbb"])
        }

        // Someone who used BITT before this fix shipped has no marker, but they
        // do have a state file — that alone has to be enough to leave them be.
        do {
            let support = sandbox()
            writeList(swarmState(support), hashes: ["aaaa", "bbbb"])
            writeList(bittState(support), hashes: [])   // migrated once, then emptied

            Check.that("an existing BITT list is never overwritten, even an empty one") {
                !Migration.carryState(in: support, log: quiet)
            }
            Check.that("so nothing comes back for them either") {
                listed(bittState(support)).isEmpty
            }
        }

        // Nothing to migrate from: must not crash, and must not keep asking.
        do {
            let support = sandbox()
            Check.that("a clean install carries nothing") {
                !Migration.carryState(in: support, log: quiet)
            }
            Check.that("and it records that it asked, so it never asks again") {
                FileManager.default.fileExists(
                    atPath: support.appendingPathComponent("BITT/.migrated-from-swarm").path)
            }
        }
    }

    // MARK: - Fixtures

    private static func sandbox() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitt-migration-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func swarmState(_ support: URL) -> URL {
        support.appendingPathComponent("Swarm/state.json")
    }

    private static func bittState(_ support: URL) -> URL {
        support.appendingPathComponent("BITT/state.json")
    }

    private static func writeList(_ url: URL, hashes: [String]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let torrents = hashes.map {
            ["hash": $0, "source": "/tmp/\($0).torrent", "dir": "/tmp",
             "paused": true, "added_at": 1.0] as [String: Any]
        }
        let json: [String: Any] = ["version": 2, "torrents": torrents]
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        try? data.write(to: url)
    }

    private static func listed(_ url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let torrents = json["torrents"] as? [[String: Any]] else { return [] }
        return torrents.compactMap { $0["hash"] as? String }
    }
}
