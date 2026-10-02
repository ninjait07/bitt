"""Tracker announces: HTTP/HTTPS (BEP 3, BEP 23) and UDP (BEP 15)."""

from __future__ import annotations

import asyncio
import ipaddress
import os
import random
import socket
import struct
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Dict, List, NamedTuple, Optional, Tuple

from . import bencode

DEFAULT_NUMWANT = 80
HTTP_TIMEOUT = 20.0
UDP_PROTOCOL_ID = 0x41727101980

EVENT_CODES = {"none": 0, "completed": 1, "started": 2, "stopped": 3}


class TrackerResponse(NamedTuple):
    peers: List[Tuple[str, int]]
    interval: int
    seeders: int
    leechers: int
    warning: str = ""


class TrackerError(Exception):
    pass


class Tracker:
    """A single tracker URL, with its own retry/backoff state."""

    def __init__(self, url: str) -> None:
        self.url = url.strip()
        parsed = urllib.parse.urlparse(self.url)
        self.scheme = parsed.scheme.lower()
        if self.scheme not in ("http", "https", "udp"):
            raise TrackerError("unsupported tracker scheme: %s" % (parsed.scheme or "?"))
        self.next_announce_at = 0.0
        self.interval = 0
        self.failures = 0
        self.last_error = ""
        self.last_peer_count = 0

    def __str__(self) -> str:
        return self.url

    @property
    def is_due(self) -> bool:
        return time.monotonic() >= self.next_announce_at

    def schedule(self, seconds: float) -> None:
        self.next_announce_at = time.monotonic() + seconds

    def note_failure(self, exc: Exception) -> None:
        self.failures += 1
        self.last_error = str(exc) or exc.__class__.__name__
        # Back off 30s, 60s, 120s ... capped at 15 minutes.
        self.schedule(min(30.0 * (2 ** min(self.failures - 1, 5)), 900.0))

    def note_success(self, response: TrackerResponse) -> None:
        self.failures = 0
        self.last_error = ""
        self.last_peer_count = len(response.peers)
        self.interval = response.interval
        self.schedule(max(60, min(response.interval, 3600)))

    async def announce(self, *, info_hash: bytes, peer_id: bytes, port: int,
                       uploaded: int, downloaded: int, left: int,
                       event: str = "none", numwant: int = DEFAULT_NUMWANT,
                       key: Optional[int] = None) -> TrackerResponse:
        key = key if key is not None else struct.unpack(">I", os.urandom(4))[0]
        args = dict(info_hash=info_hash, peer_id=peer_id, port=port, uploaded=uploaded,
                    downloaded=downloaded, left=left, event=event, numwant=numwant, key=key)
        if self.scheme == "udp":
            return await asyncio.get_event_loop().run_in_executor(None, lambda: _udp_announce(self.url, **args))
        return await asyncio.get_event_loop().run_in_executor(None, lambda: _http_announce(self.url, **args))


# -- HTTP ---------------------------------------------------------------------

def _http_announce(url: str, *, info_hash: bytes, peer_id: bytes, port: int,
                   uploaded: int, downloaded: int, left: int, event: str,
                   numwant: int, key: int) -> TrackerResponse:
    query = {
        "info_hash": info_hash,
        "peer_id": peer_id,
        "port": str(port),
        "uploaded": str(uploaded),
        "downloaded": str(downloaded),
        "left": str(left),
        "compact": "1",
        "numwant": str(numwant),
        "key": "%08x" % key,
    }
    if event != "none":
        query["event"] = event

    separator = "&" if urllib.parse.urlparse(url).query else "?"
    full = url + separator + urllib.parse.urlencode(query, safe="", quote_via=urllib.parse.quote)

    request = urllib.request.Request(full, headers={
        "User-Agent": "pytorrent/1.0",
        "Accept-Encoding": "gzip",
        "Connection": "close",
    })
    try:
        with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT) as response:
            body = response.read(2 * 1024 * 1024)
            if response.headers.get("Content-Encoding") == "gzip":
                import gzip

                body = gzip.decompress(body)
    except urllib.error.HTTPError as exc:
        raise TrackerError("HTTP %s from tracker" % exc.code)
    except urllib.error.URLError as exc:
        raise TrackerError(str(exc.reason))
    except (OSError, ValueError) as exc:
        raise TrackerError(str(exc))

    return _parse_http_response(body)


def _parse_http_response(body: bytes) -> TrackerResponse:
    try:
        data = bencode.decode(body)
    except bencode.BencodeError:
        raise TrackerError("tracker sent a malformed response")
    if not isinstance(data, dict):
        raise TrackerError("tracker sent a malformed response")

    failure = data.get(b"failure reason")
    if failure:
        raise TrackerError(failure.decode("utf-8", "replace") if isinstance(failure, bytes) else str(failure))

    warning = data.get(b"warning message", b"")
    peers: List[Tuple[str, int]] = []
    raw_peers = data.get(b"peers")
    if isinstance(raw_peers, bytes):
        peers.extend(_unpack_compact(raw_peers, 4))
    elif isinstance(raw_peers, list):
        for entry in raw_peers:
            if not isinstance(entry, dict):
                continue
            ip = entry.get(b"ip")
            peer_port = entry.get(b"port")
            if isinstance(ip, bytes) and isinstance(peer_port, int):
                peers.append((ip.decode("utf-8", "replace"), peer_port))
    raw_peers6 = data.get(b"peers6")
    if isinstance(raw_peers6, bytes):
        peers.extend(_unpack_compact(raw_peers6, 16))

    return TrackerResponse(
        peers=_dedupe(peers),
        interval=int(data.get(b"interval", 1800) or 1800),
        seeders=int(data.get(b"complete", 0) or 0),
        leechers=int(data.get(b"incomplete", 0) or 0),
        warning=warning.decode("utf-8", "replace") if isinstance(warning, bytes) else "",
    )


def _unpack_compact(raw: bytes, address_size: int) -> List[Tuple[str, int]]:
    stride = address_size + 2
    out: List[Tuple[str, int]] = []
    for offset in range(0, len(raw) - stride + 1, stride):
        chunk = raw[offset : offset + stride]
        try:
            address = ipaddress.ip_address(chunk[:address_size])
        except ValueError:
            continue
        (peer_port,) = struct.unpack(">H", chunk[address_size:])
        if peer_port:
            out.append((str(address), peer_port))
    return out


def _dedupe(peers: List[Tuple[str, int]]) -> List[Tuple[str, int]]:
    seen = set()
    out = []
    for peer in peers:
        if peer not in seen:
            seen.add(peer)
            out.append(peer)
    return out


# -- UDP (BEP 15) -------------------------------------------------------------

def _udp_announce(url: str, *, info_hash: bytes, peer_id: bytes, port: int,
                  uploaded: int, downloaded: int, left: int, event: str,
                  numwant: int, key: int) -> TrackerResponse:
    parsed = urllib.parse.urlparse(url)
    if not parsed.hostname or not parsed.port:
        raise TrackerError("udp tracker URL needs host and port")

    try:
        infos = socket.getaddrinfo(parsed.hostname, parsed.port, 0, socket.SOCK_DGRAM)
    except socket.gaierror as exc:
        raise TrackerError("cannot resolve %s: %s" % (parsed.hostname, exc))
    family, socket_type, protocol, _, address = infos[0]

    sock = socket.socket(family, socket_type, protocol)
    try:
        sock.settimeout(5.0)

        connection_id = _udp_connect(sock, address)

        transaction_id = struct.unpack(">I", os.urandom(4))[0]
        request = struct.pack(
            ">QII20s20sQQQIIiH",
            connection_id, 1, transaction_id, info_hash, peer_id,
            downloaded, left, uploaded, EVENT_CODES.get(event, 0),
            0, key, numwant, port,
        )
        body = _udp_exchange(sock, address, request, transaction_id, expect_action=1, minimum=20)

        interval, leechers, seeders = struct.unpack(">III", body[:12])
        peers = _unpack_compact(body[12:], 4 if family == socket.AF_INET else 16)
        return TrackerResponse(_dedupe(peers), int(interval) or 1800, int(seeders), int(leechers))
    finally:
        sock.close()


def _udp_connect(sock: socket.socket, address) -> int:
    transaction_id = struct.unpack(">I", os.urandom(4))[0]
    request = struct.pack(">QII", UDP_PROTOCOL_ID, 0, transaction_id)
    body = _udp_exchange(sock, address, request, transaction_id, expect_action=0, minimum=8)
    (connection_id,) = struct.unpack(">Q", body[:8])
    return connection_id


def _udp_exchange(sock: socket.socket, address, request: bytes,
                  transaction_id: int, expect_action: int, minimum: int) -> bytes:
    """Send and wait for the matching reply, retrying per BEP 15 (15s, 30s, 60s)."""
    last_error = "no response"
    for attempt in range(3):
        sock.settimeout(min(15.0 * (2 ** attempt), 60.0) if attempt else 8.0)
        try:
            sock.sendto(request, address)
        except OSError as exc:
            raise TrackerError(str(exc))
        deadline = time.monotonic() + sock.gettimeout()
        while time.monotonic() < deadline:
            try:
                data, _ = sock.recvfrom(4096)
            except socket.timeout:
                break
            except OSError as exc:
                raise TrackerError(str(exc))
            if len(data) < 8:
                continue
            action, reply_transaction = struct.unpack(">II", data[:8])
            if reply_transaction != transaction_id:
                continue
            if action == 3:  # error
                raise TrackerError(data[8:].decode("utf-8", "replace").strip() or "tracker error")
            if action != expect_action or len(data) < 8 + minimum:
                last_error = "unexpected reply from tracker"
                continue
            return data[8:]
    raise TrackerError(last_error)


def build_trackers(urls: List[str]) -> List[Tracker]:
    trackers: List[Tracker] = []
    seen = set()
    for url in urls:
        clean = url.strip()
        if not clean or clean in seen:
            continue
        seen.add(clean)
        try:
            trackers.append(Tracker(clean))
        except TrackerError:
            continue
    random.shuffle(trackers)
    return trackers
