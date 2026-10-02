import Foundation

enum TrackerTests {
    static func run(fixtures: URL?) {
        Check.section("Tracker")

        Check.that("parses a compact peer list") {
            var raw = Data([1, 2, 3, 4]); raw.append(contentsOf: [0x1A, 0xE1])
            raw.append(contentsOf: [10, 0, 0, 1, 0xC8, 0xD5])
            let peers = HTTPTracker.unpackCompact(raw, addressSize: 4)
            return peers.map(\.description) == ["1.2.3.4:6881", "10.0.0.1:51413"]
        }

        Check.that("parses a full announce response") {
            var body = Data("d8:intervali900e8:completei5e10:incompletei2e5:peers12:".utf8)
            body.append(contentsOf: [1, 2, 3, 4, 0x1A, 0xE1, 10, 0, 0, 1, 0xC8, 0xD5])
            body.append(contentsOf: Data("e".utf8))
            let response = try HTTPTracker.parse(body)
            return response.interval == 900 && response.seeders == 5 && response.leechers == 2
                && response.peers.count == 2
        }

        Check.that("parses a dictionary peer list") {
            let body = Data("d8:intervali900e5:peersld2:ip9:127.0.0.14:porti6881eeee".utf8)
            let response = try HTTPTracker.parse(body)
            return response.peers.map(\.description) == ["127.0.0.1:6881"]
        }

        Check.throwsError("surfaces a failure reason") {
            try HTTPTracker.parse(Data("d14:failure reason9:not founde".utf8))
        }

        Check.throwsError("rejects an unsupported scheme") {
            try Tracker(url: "ftp://example.org/announce")
        }

        Check.that("build drops duplicates and bad URLs") {
            let trackers = Tracker.build(["udp://x.org:80/a", "http://y.org/a",
                                          "ftp://nope", "http://y.org/a"])
            return Set(trackers.map(\.url)) == ["udp://x.org:80/a", "http://y.org/a"]
        }

        Check.that("backoff grows and success resets it") {
            let tracker = try Tracker(url: "http://y.org/a")
            tracker.noteFailure(TrackerError.noResponse)
            let firstDelay = tracker.nextAnnounceAt - Date().timeIntervalSinceReferenceDate
            tracker.noteFailure(TrackerError.noResponse)
            let secondDelay = tracker.nextAnnounceAt - Date().timeIntervalSinceReferenceDate
            tracker.noteSuccess(TrackerResponse())
            return firstDelay > 25 && secondDelay > firstDelay && tracker.failures == 0
        }

        Check.section("Addresses")

        Check.equal("host:port", PeerAddress("1.2.3.4:6881")?.description, "1.2.3.4:6881")
        Check.equal("bracketed IPv6", PeerAddress("[::1]:6881")?.host, "::1")
        for bad in ["", "nope", "h:0", "h:99999", "[::1]6881", "a:b:c"] {
            Check.that("rejects \(bad.isEmpty ? "(empty)" : bad)") { PeerAddress(bad) == nil }
        }

        guard let fixtures,
              let data = try? Data(contentsOf: fixtures.appendingPathComponent("wire.json")),
              let expected = (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
        else { return }

        Check.section("Announce encoding vs the Python engine")
        let infoHash = Data((0..<20).map { UInt8($0 &* 13) })
        Check.equal("percent-encoded info_hash",
                    HTTPTracker.percentEncode(infoHash),
                    expected["quoted_info_hash"] ?? "missing")
        Check.equal("percent-encoded peer_id",
                    HTTPTracker.percentEncode(Data("-SW1000-abcdef123456".utf8)),
                    expected["quoted_peer_id"] ?? "missing")
    }
}
