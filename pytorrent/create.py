"""Build a .torrent file from a local file or directory."""

from __future__ import annotations

import hashlib
import os
import time
from typing import Callable, List, Optional

from . import bencode
from .metainfo import Metainfo


def pick_piece_length(total: int) -> int:
    """Aim for a few thousand pieces: 16 KiB .. 16 MiB, always a power of two."""
    target = 16 * 1024
    while total // target > 2000 and target < 16 * 1024 * 1024:
        target *= 2
    return target


def create_torrent(path: str, trackers: Optional[List[str]] = None, *,
                   piece_length: Optional[int] = None, private: bool = False,
                   comment: str = "", progress: Optional[Callable[[int, int], None]] = None) -> bytes:
    path = os.path.abspath(path.rstrip(os.sep) or os.sep)
    if not os.path.exists(path):
        raise FileNotFoundError(path)

    name = os.path.basename(path)
    files: List[tuple] = []  # (absolute path, relative parts, size)

    if os.path.isfile(path):
        files.append((path, [name], os.path.getsize(path)))
    else:
        for root, dirnames, filenames in os.walk(path):
            dirnames.sort()
            for filename in sorted(filenames):
                if filename.startswith("."):
                    continue
                full = os.path.join(root, filename)
                if os.path.islink(full) or not os.path.isfile(full):
                    continue
                relative = os.path.relpath(full, path).split(os.sep)
                files.append((full, relative, os.path.getsize(full)))
        if not files:
            raise ValueError("no files found under %s" % path)

    total = sum(size for _, _, size in files)
    piece_length = piece_length or pick_piece_length(total)

    hashes = bytearray()
    buffer = bytearray()
    processed = 0
    for full, _, _ in files:
        with open(full, "rb") as handle:
            while True:
                chunk = handle.read(1024 * 1024)
                if not chunk:
                    break
                buffer.extend(chunk)
                processed += len(chunk)
                while len(buffer) >= piece_length:
                    hashes.extend(hashlib.sha1(bytes(buffer[:piece_length])).digest())
                    del buffer[:piece_length]
                if progress:
                    progress(processed, total)
    if buffer:
        hashes.extend(hashlib.sha1(bytes(buffer)).digest())

    info = {
        b"name": name.encode("utf-8"),
        b"piece length": piece_length,
        b"pieces": bytes(hashes),
    }
    if os.path.isfile(path):
        info[b"length"] = total
    else:
        info[b"files"] = [
            {b"length": size, b"path": [part.encode("utf-8") for part in relative]}
            for _, relative, size in files
        ]
    if private:
        info[b"private"] = 1

    meta = {
        b"info": info,
        b"creation date": int(time.time()),
        b"created by": b"pytorrent 1.0",
        b"encoding": b"UTF-8",
    }
    if comment:
        meta[b"comment"] = comment.encode("utf-8")
    trackers = [t for t in (trackers or []) if t.strip()]
    if trackers:
        meta[b"announce"] = trackers[0].encode("utf-8")
        meta[b"announce-list"] = [[t.encode("utf-8")] for t in trackers]

    return bencode.encode(meta)


def magnet_for(meta: Metainfo) -> str:
    import urllib.parse

    parts = ["xt=urn:btih:" + meta.info_hash.hex()]
    parts.append("dn=" + urllib.parse.quote(meta.name))
    for tracker in meta.trackers:
        parts.append("tr=" + urllib.parse.quote(tracker, safe=""))
    return "magnet:?" + "&".join(parts)
