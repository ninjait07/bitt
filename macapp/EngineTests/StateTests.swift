import Foundation

enum StateTests {
    static func run() {
        Check.section("Saved state")

        // What the very first BITT wrote, through the Python engine.
        let version1 = """
        {"version": 1,
         "settings": {"download_dir": "/Users/me/Movies", "port": 6881,
                      "max_peers": 60, "seed_after_complete": true, "max_active": 8},
         "torrents": [{"hash": "aa", "source": "/x/aa.torrent",
                       "dir": "/Users/me/Movies", "paused": true, "added_at": 1.0},
                      {"hash": "bb", "source": "magnet:?xt=urn:btih:bb",
                       "dir": "/Users/me/Elsewhere", "paused": false, "added_at": 2.0}]}
        """

        Check.that("reads the original Python-engine file") {
            guard let state = TorrentManager.parseState(Data(version1.utf8)) else { return false }
            return state.settings.downloadDirectory == "/Users/me/Movies"
                && state.torrents.count == 2
                && state.torrents.first { $0.hash == "aa" }?.directory == "/Users/me/Movies"
                && state.torrents.first { $0.hash == "bb" }?.directory == "/Users/me/Elsewhere"
                && state.torrents.first { $0.hash == "aa" }?.paused == true
        }

        // A file written before the speed limits and port mapping existed. The
        // synthesised decoder would throw on the first missing key, and the
        // legacy reader would then mis-parse it and move every torrent.
        let version2Old = """
        {"version": 2,
         "settings": {"downloadDirectory": "/Users/me/Movies", "listenPort": 6881,
                      "maxPeers": 60, "seedAfterComplete": true},
         "torrents": [{"hash": "aa", "source": "/x/aa.torrent",
                       "directory": "/Users/me/Movies", "paused": true}]}
        """

        Check.that("reads a file that predates the newer settings") {
            guard let state = TorrentManager.parseState(Data(version2Old.utf8)) else { return false }
            return state.settings.downloadDirectory == "/Users/me/Movies"
                && state.settings.downloadLimit == 0
                && state.settings.mapPortAutomatically
                && state.torrents.first?.directory == "/Users/me/Movies"
                && state.torrents.first?.paused == true
        }

        Check.that("keeps the ratio totals when they are present") {
            let withTotals = """
            {"version": 2, "settings": {"downloadDirectory": "/d"},
             "torrents": [{"hash": "aa", "source": "s", "directory": "/d",
                           "paused": false, "downloaded": 100, "uploaded": 250}]}
            """
            guard let state = TorrentManager.parseState(Data(withTotals.utf8)) else { return false }
            return state.torrents.first?.downloaded == 100
                && state.torrents.first?.uploaded == 250
        }

        Check.that("refuses a file that is neither shape") {
            TorrentManager.parseState(Data(#"{"hello": "world"}"#.utf8))?.torrents.isEmpty ?? true
        }

        Check.that("a current file round trips") {
            var state = TorrentManager.StoredState()
            state.settings.downloadDirectory = "/Users/me/Downloads"
            state.settings.uploadLimit = 512 * 1024
            state.torrents = [.init(hash: "cc", source: "magnet:?xt=urn:btih:cc",
                                    directory: "/Users/me/Downloads", paused: false,
                                    downloaded: 7, uploaded: 9)]
            let data = try JSONEncoder().encode(state)
            guard let back = TorrentManager.parseState(data) else { return false }
            return back.settings == state.settings
                && back.torrents.first?.uploaded == 9
                && back.torrents.first?.directory == "/Users/me/Downloads"
        }
    }
}
