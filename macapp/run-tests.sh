#!/bin/bash
# Builds and runs the Swift engine tests.
#
# Fixtures are produced by the Python engine so the Swift port can be compared
# against the implementation that is already known to interoperate with real
# clients.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
OUT="${TMPDIR:-/tmp}/bitt-engine-tests"
FIXTURES="${TMPDIR:-/tmp}/bitt-fixtures"

echo "==> Building fixtures with the Python engine"
rm -rf "$FIXTURES"
mkdir -p "$FIXTURES/payload/inner"
python3 - "$FIXTURES" <<'PY'
import os, sys
root = os.path.join(sys.argv[1], "payload")
# Deterministic content, so a rerun compares like with like.
with open(os.path.join(root, "one.bin"), "wb") as handle:
    handle.write(bytes(i % 251 for i in range(300_000)))
with open(os.path.join(root, "inner", "two.txt"), "wb") as handle:
    handle.write(b"swarm fixture\n" * 900)
PY
"$ROOT/torrentdl" create "$FIXTURES/payload" \
    -o "$FIXTURES/sample.torrent" \
    --tracker "udp://tracker.example:1337/announce" \
    --tracker "http://tracker2.example/announce" > /dev/null

python3 - "$FIXTURES" "$ROOT" <<'PY'
import json, os, sys
sys.path.insert(0, sys.argv[2])
from pytorrent.metainfo import Metainfo
meta = Metainfo.from_file(os.path.join(sys.argv[1], "sample.torrent"))
json.dump({
    "info_hash": meta.info_hash.hex(),
    "name": meta.name,
    "piece_length": meta.piece_length,
    "piece_count": meta.piece_count,
    "total_length": meta.total_length,
    "trackers": meta.trackers,
    "paths": [f.path for f in meta.files],
    "offsets": [f.offset for f in meta.files],
    "piece_hashes": [h.hex() for h in meta.piece_hashes],
}, open(os.path.join(sys.argv[1], "expected.json"), "w"))
PY

python3 - "$FIXTURES" "$ROOT" <<'PY'
import json, os, sys
sys.path.insert(0, sys.argv[2])
from pytorrent import protocol as p

info_hash = b"A" * 20
peer_id = b"-PY0001-123456789012"
frames = {
    "handshake": p.make_handshake(info_hash, peer_id),
    "keepalive": p.frame(None),
    "choke": p.frame(p.CHOKE),
    "unchoke": p.frame(p.UNCHOKE),
    "interested": p.frame(p.INTERESTED),
    "not_interested": p.frame(p.NOT_INTERESTED),
    "have_5": p.msg_have(5),
    "request": p.msg_request(1, 0, 16384),
    "cancel": p.msg_cancel(7, 32768, 16384),
    "piece": p.msg_piece(3, 16384, b"hello"),
    "bitfield": p.msg_bitfield(bytes([0xF0, 0x0F])),
    "metadata_request": p.ut_metadata_request(1),
    "metadata_reject": p.ut_metadata_reject(1),
    "metadata_data": p.ut_metadata_data(0, 6961, b"abc"),
    "extended_handshake": p.extended_handshake_payload(6961, b"pytorrent 1.0", 6881),
}
import urllib.parse
out = {k: v.hex() for k, v in frames.items()}
out["quoted_info_hash"] = urllib.parse.quote(bytes((i * 13) % 256 for i in range(20)), safe="")
out["quoted_peer_id"] = urllib.parse.quote(b"-SW1000-abcdef123456", safe="")
json.dump(out, open(os.path.join(sys.argv[1], "wire.json"), "w"))
PY

echo "==> Compiling the Swift engine and its tests"
swiftc -O -target arm64-apple-macos13.0 -o "$OUT" \
    "$HERE"/Sources/Engine/*.swift \
    "$HERE"/Sources/Migration.swift "$HERE"/Sources/AppLog.swift \
    "$HERE"/EngineTests/*.swift

echo "==> Starting a Python seeder for the cross-check"
PY_PORT=39950
"$ROOT/torrentdl" seed "$FIXTURES/sample.torrent" -o "$FIXTURES" -p "$PY_PORT" -q \
    > /dev/null 2>&1 &
PY_PID=$!
trap 'kill $PY_PID 2>/dev/null || true' EXIT
sleep 2

"$OUT" "$FIXTURES" "$PY_PORT"
