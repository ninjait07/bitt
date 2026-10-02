"""Torrent metainfo: .torrent files, magnet URIs, and the info dict itself."""

from __future__ import annotations

import hashlib
import os
import urllib.parse
from typing import Any, Dict, List, NamedTuple, Optional

from . import bencode

BLOCK_SIZE = 16 * 1024
MAX_PIECE_LENGTH = 64 * 1024 * 1024   # a piece is buffered in memory while it downloads
MAX_PIECES = 4_000_000                # guards against a hostile 'pieces' string
MAX_TOTAL_LENGTH = 1 << 50            # 1 PiB


class FileEntry(NamedTuple):
    """One file in the torrent, placed at [offset, offset+length) of the stream."""

    path: str  # relative path, os separators, already sanitised
    length: int
    offset: int


class MetainfoError(ValueError):
    pass


def _text(raw: Any, default: str = "") -> str:
    if isinstance(raw, bytes):
        return raw.decode("utf-8", "replace")
    if isinstance(raw, str):
        return raw
    return default


def _safe_component(raw: Any) -> Optional[str]:
    """Reject path components that could escape the download directory."""
    name = _text(raw).strip()
    if name in ("", ".", "..") or "/" in name or "\\" in name or "\x00" in name:
        return None
    return name


class Metainfo:
    """A fully known torrent: the `info` dict plus where it came from."""

    def __init__(self, info: Dict[bytes, Any], trackers: Optional[List[str]] = None,
                 raw_info: Optional[bytes] = None) -> None:
        self.info = info
        self.raw_info = raw_info if raw_info is not None else bencode.encode(info)
        self.info_hash = hashlib.sha1(self.raw_info).digest()
        self.trackers: List[str] = list(trackers or [])

        self.piece_length = int(info.get(b"piece length", 0))
        if self.piece_length < BLOCK_SIZE or self.piece_length > MAX_PIECE_LENGTH:
            raise MetainfoError(
                "'piece length' of %d is outside the usable range (%d..%d)"
                % (self.piece_length, BLOCK_SIZE, MAX_PIECE_LENGTH)
            )

        pieces = info.get(b"pieces", b"")
        if not isinstance(pieces, bytes) or len(pieces) == 0 or len(pieces) % 20 != 0:
            raise MetainfoError("missing or malformed 'pieces'")
        if len(pieces) // 20 > MAX_PIECES:
            raise MetainfoError("torrent declares %d pieces" % (len(pieces) // 20))
        self.piece_hashes: List[bytes] = [pieces[i : i + 20] for i in range(0, len(pieces), 20)]

        self.name = _safe_component(info.get(b"name")) or self.info_hash.hex()
        self.private = bool(info.get(b"private", 0))
        self.files, self.total_length = self._parse_files(info)

        expected_pieces = (self.total_length + self.piece_length - 1) // self.piece_length
        if expected_pieces != len(self.piece_hashes):
            raise MetainfoError(
                "piece count mismatch: %d hashes for %d bytes of %d-byte pieces"
                % (len(self.piece_hashes), self.total_length, self.piece_length)
            )

    def _parse_files(self, info: Dict[bytes, Any]):
        raw_files = info.get(b"files")
        if raw_files is None:
            length = int(info.get(b"length", -1))
            if length < 0:
                raise MetainfoError("single-file torrent without 'length'")
            return [FileEntry(self.name, length, 0)], length

        if not isinstance(raw_files, list) or not raw_files:
            raise MetainfoError("malformed 'files' list")

        entries: List[FileEntry] = []
        offset = 0
        for index, item in enumerate(raw_files):
            if not isinstance(item, dict):
                raise MetainfoError("malformed entry in 'files'")
            length = int(item.get(b"length", -1))
            if length < 0:
                raise MetainfoError("file entry without 'length'")
            if offset + length > MAX_TOTAL_LENGTH:
                raise MetainfoError("torrent is implausibly large")
            parts = [_safe_component(p) for p in item.get(b"path", [])]
            clean = [p for p in parts if p]
            if not clean:
                clean = ["file_%d" % index]
            entries.append(FileEntry(os.path.join(*clean), length, offset))
            offset += length
        return entries, offset

    @property
    def piece_count(self) -> int:
        return len(self.piece_hashes)

    def piece_size(self, index: int) -> int:
        """Size of a piece; the last one is usually short."""
        if index < 0 or index >= self.piece_count:
            raise IndexError(index)
        if index == self.piece_count - 1:
            remainder = self.total_length - self.piece_length * index
            return remainder if remainder > 0 else self.piece_length
        return self.piece_length

    def block_count(self, index: int) -> int:
        size = self.piece_size(index)
        return (size + BLOCK_SIZE - 1) // BLOCK_SIZE

    def is_multi_file(self) -> bool:
        return b"files" in self.info

    def to_torrent_bytes(self) -> bytes:
        """Re-emit a .torrent file, splicing in the original info bytes verbatim.

        Bencode dict keys are sorted, and "announce" < "announce-list" < "info",
        so the pieces can simply be concatenated in that order.
        """
        parts = [b"d"]
        if self.trackers:
            first = self.trackers[0].encode("utf-8")
            parts.append(b"8:announce%d:%s" % (len(first), first))
            parts.append(b"13:announce-list")
            parts.append(bencode.encode([[t.encode("utf-8")] for t in self.trackers]))
        parts.append(b"4:info")
        parts.append(self.raw_info)
        parts.append(b"e")
        return b"".join(parts)

    @classmethod
    def from_info_bytes(cls, raw_info: bytes, trackers: Optional[List[str]] = None) -> "Metainfo":
        """Build from raw bencoded info bytes (as fetched over ut_metadata)."""
        info = bencode.decode(raw_info)
        if not isinstance(info, dict):
            raise MetainfoError("info is not a dictionary")
        return cls(info, trackers, raw_info=raw_info)

    @classmethod
    def from_file(cls, path: str) -> "Metainfo":
        with open(path, "rb") as handle:
            data = handle.read()
        return cls.from_bytes(data)

    @classmethod
    def from_bytes(cls, data: bytes) -> "Metainfo":
        try:
            meta = bencode.decode(data)
        except bencode.BencodeError as exc:
            raise MetainfoError("not a valid .torrent file: %s" % exc)
        if not isinstance(meta, dict) or b"info" not in meta:
            raise MetainfoError("not a valid .torrent file: no 'info' dictionary")

        # Re-encode the info dict from its decoded form: our encoder sorts keys
        # exactly as bencode requires, so this reproduces the original bytes.
        raw_info = bencode.encode(meta[b"info"])
        return cls(meta[b"info"], _trackers_from_metafile(meta), raw_info=raw_info)


def _trackers_from_metafile(meta: Dict[bytes, Any]) -> List[str]:
    trackers: List[str] = []

    def add(raw: Any) -> None:
        url = _text(raw).strip()
        if url and url not in trackers:
            trackers.append(url)

    # announce-list is tiered; we flatten it but keep tier order.
    for tier in meta.get(b"announce-list", []) or []:
        if isinstance(tier, list):
            for url in tier:
                add(url)
        else:
            add(tier)
    add(meta.get(b"announce"))
    return trackers


class MagnetLink(NamedTuple):
    info_hash: bytes
    display_name: str
    trackers: List[str]
    peers: List[str]  # x.pe= direct peer hints


def parse_magnet(uri: str) -> MagnetLink:
    """Parse a magnet: URI with a BitTorrent info-hash (BEP 9 / BEP 53)."""
    if not uri.lower().startswith("magnet:"):
        raise MetainfoError("not a magnet link")

    query = urllib.parse.parse_qs(uri[len("magnet:") :].lstrip("?"), keep_blank_values=False)

    info_hash: Optional[bytes] = None
    for xt in query.get("xt", []):
        prefix = "urn:btih:"
        if not xt.lower().startswith(prefix):
            continue
        digest = xt[len(prefix) :]
        if len(digest) == 40:
            try:
                info_hash = bytes.fromhex(digest)
            except ValueError:
                continue
        elif len(digest) == 32:
            import base64

            try:
                info_hash = base64.b32decode(digest.upper())
            except Exception:
                continue
        if info_hash:
            break

    if info_hash is None:
        if any(x.lower().startswith("urn:btmh:") for x in query.get("xt", [])):
            raise MetainfoError("BitTorrent v2 magnet links (btmh) are not supported")
        raise MetainfoError("magnet link has no usable btih info-hash")

    name = query.get("dn", [""])[0]
    trackers = [t for t in query.get("tr", []) if t.strip()]
    peers = [p for p in query.get("x.pe", []) if p.strip()]
    return MagnetLink(info_hash, name, trackers, peers)
