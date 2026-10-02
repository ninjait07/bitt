# BITT

**A small BitTorrent client for macOS, for people who already have a tracker site.**

BITT lives in the menu bar. The app is native SwiftUI and the BitTorrent engine is
plain Swift compiled into the same binary — one process, about 3.5 MB, no runtime to
install and no third-party dependencies.

[อ่านฉบับภาษาไทย](README.th.md)

---

## Scope — this is deliberately small

BITT is built for one situation: you get `.torrent` files and magnet links from a
site you already use, and you want them downloaded without fuss.

**It works with** any torrent or magnet that carries trackers, which is effectively
everything a site hands you. Private trackers always attach their announce URL with
your passkey; public sites attach a long list.

**It does not do DHT (BEP 5) or PEX (BEP 11)**, and that is a decision rather than a
gap:

1. **Private trackers forbid both.** Those torrents set the `private` flag, and
   announcing them to the DHT is a good way to lose your account. For the intended
   user it is not merely unnecessary, it is harmful.
2. **Site magnets already carry trackers**, so the DHT would add nothing in practice.
3. **A DHT node is never idle.** It answers UDP from the whole world whether or not
   you are downloading, which works against the point of a small client — and it is
   another ~1,000 lines to carry, roughly a quarter of the engine again.

The consequence: a bare magnet with only `xt=urn:btih:…` and no `&tr=` will not
work. BITT says so in the add dialog instead of leaving it stuck at 0%.

If that trade ever needs revisiting the order would be: enforce the `private` flag
properly, then PEX, then DHT.

## What it does

- `.torrent` files, magnet links, and `http(s)` URLs that point at a `.torrent`
- Fetches a magnet's file list from peers (BEP 9 / BEP 10 `ut_metadata`)
- HTTP and UDP trackers (BEP 15), compact peer lists including IPv6 (BEP 23)
- Rarest-first piece selection with an endgame, tit-for-tat choking with an
  optimistic unchoke
- Verifies SHA-1 on every piece before it reaches the disk; bad data is refetched
- Resumes by hash-checking what is already on disk — no separate state file to
  corrupt
- Upload and download speed limits shared across torrents
- Ratio and cumulative shared bytes, counted across restarts
- Asks the router to forward the listening port (NAT-PMP, then UPnP IGD) and tells
  you plainly when it could not
- Seeds in the background with no window open
- Liquid Glass on floating surfaces on macOS 26+, older materials below that

## Install

No notarised release yet, so build it:

```bash
git clone https://github.com/ninjait07/bitt.git
cd bitt
bash macapp/build.sh --install
```

Needs Xcode Command Line Tools. The build compiles the app, draws the icon, writes
the bundle and copies it to `/Applications`. `--dmg` writes a disk image to `dist/`,
and `--out <dir>` puts it somewhere else.

## Layout

The engine exists twice, on purpose.

```
macapp/Sources/Engine/   the Swift engine — this is what the app runs
macapp/Sources/          the SwiftUI app: menu bar, window, settings
macapp/EngineTests/      125 tests for the Swift engine
pytorrent/               the same protocol in Python — reference and CLI
torrentdl                command line client built on the Python engine
tests/                   34 tests for the Python engine
```

The Python engine came first and was validated against real swarms. The Swift port
is checked against it on every test run, which is what makes the port trustworthy.

## Testing

```bash
bash macapp/run-tests.sh    # 125 tests, Swift engine
python3 tests/test_units.py # 28 tests, Python engine
python3 tests/test_swarm.py #  6 tests, real sockets on loopback
```

`run-tests.sh` builds its fixtures with the Python engine and then holds the Swift
engine against them:

- **Every wire frame is compared byte for byte** — handshake, request, piece,
  bitfield, `ut_metadata`, the extended handshake (which depends on bencode key
  order), and the percent-encoding of a tracker announce
- Every value read from a real `.torrent` matches, including all piece hashes
- Real transfers over real sockets: Swift to Swift through a magnet link, and a
  Swift leecher downloading from the Python seeder

Both engines have downloaded the Debian 13.7 netinst ISO (756 MiB) to completion
from the public swarm, against qBittorrent, Transmission, Deluge and rqbit peers at
9–11 MiB/s, with the resulting SHA-256 matching Debian's published checksum and zero
failed pieces.

## Known limits

- No DHT or PEX — see **Scope** above
- No connection encryption (MSE/PE), so some ISPs may throttle
- No BitTorrent v2 (`btmh:` magnets)
- Builds are ad-hoc signed; copying the app between machines trips Gatekeeper until
  it is signed with a Developer ID and notarised

## Licence

GPL-3.0. See [LICENSE](LICENSE).

BitTorrent is a trademark of Rainberry, Inc. BITT is not affiliated with or endorsed
by them. What you choose to download with it is your own responsibility.
