"""Ties everything together: trackers, peers, pieces and disk."""

from __future__ import annotations

import asyncio
import collections
import hashlib
import os
import random
import struct
import time
from typing import Any, Deque, Dict, List, Optional, Set, Tuple, Union

from . import protocol as proto
from .metainfo import MagnetLink, Metainfo, MetainfoError
from .peer import Peer
from .pieces import PieceManager
from .storage import Storage
from .tracker import Tracker, TrackerError, TrackerResponse, build_trackers

CLIENT_VERSION = b"pytorrent 1.0"
PEER_ID_PREFIX = b"-PY1000-"

MAX_UNCHOKED = 4
CHOKE_INTERVAL = 10.0
OPTIMISTIC_INTERVAL = 30.0
CONNECT_INTERVAL = 0.25
PEER_RETRY_BASE = 60.0
PIECE_CACHE_SIZE = 8


def make_peer_id() -> bytes:
    return PEER_ID_PREFIX + os.urandom(6).hex().encode("ascii")[:12]


class Session:
    def __init__(self, source: Union[Metainfo, MagnetLink], download_dir: str, *,
                 listen_port: int = 6881, max_peers: int = 60,
                 extra_trackers: Optional[List[str]] = None,
                 extra_peers: Optional[List[Tuple[str, int]]] = None,
                 seed: bool = False, verify: bool = True, quiet: bool = False,
                 upload_enabled: bool = True, listener=None,
                 stay_alive: bool = False, paused: bool = False) -> None:
        self.client_version = CLIENT_VERSION
        self.peer_id = make_peer_id()
        self.listen_port = listen_port
        self.max_peers = max_peers
        self.seed_after_complete = seed
        self.verify_on_start = verify
        self.quiet = quiet
        self.upload_enabled = upload_enabled
        self.download_dir = os.path.abspath(download_dir)
        # In a multi-torrent client the listening port is shared; a session run
        # on its own binds one itself.
        self._listener = listener
        # stay_alive keeps the session running after the download finishes, so a
        # long-lived client decides when to drop it.
        self.stay_alive = stay_alive
        self.paused = paused
        self.added_at = time.time()

        self.meta: Optional[Metainfo] = None
        self.pieces: Optional[PieceManager] = None
        self.storage: Optional[Storage] = None

        tracker_urls: List[str] = list(extra_trackers or [])
        hinted_peers: List[Tuple[str, int]] = list(extra_peers or [])

        if isinstance(source, Metainfo):
            self.meta = source
            self.info_hash = source.info_hash
            self.display_name = source.name
            tracker_urls = source.trackers + tracker_urls
            self._raw_metadata: Optional[bytes] = source.raw_info
        else:
            self.info_hash = source.info_hash
            self.display_name = source.display_name or source.info_hash.hex()
            tracker_urls = list(source.trackers) + tracker_urls
            self._raw_metadata = None
            for hint in source.peers:
                parsed = parse_address(hint)
                if parsed:
                    hinted_peers.append(parsed)

        self.trackers: List[Tracker] = build_trackers(tracker_urls)

        # metadata (BEP 9) state
        self._metadata_size: Optional[int] = len(self._raw_metadata) if self._raw_metadata else None
        self._metadata_pieces: Dict[int, bytes] = {}

        # peer pool
        self.peers: Dict[int, Peer] = {}
        self._candidates: Deque[Tuple[str, int]] = collections.deque()
        self._queued: Set[Tuple[str, int]] = set()
        self._connecting: Set[Tuple[str, int]] = set()
        self._connected_addresses: Set[Tuple[str, int]] = set()
        self._retry_at: Dict[Tuple[str, int], float] = {}
        self._failures: Dict[Tuple[str, int], int] = {}
        for address in hinted_peers:
            self.add_peer_address(address)

        # stats
        self.downloaded = 0
        self.uploaded = 0
        self.download_rate = 0.0
        self.upload_rate = 0.0
        self._rate_samples: Deque[Tuple[float, int, int]] = collections.deque(maxlen=12)
        self.started_at = time.monotonic()
        self.status_line = "starting"
        self.errors: Deque[str] = collections.deque(maxlen=40)
        self.completed_at: Optional[float] = None

        self._piece_cache: "collections.OrderedDict[int, bytes]" = collections.OrderedDict()
        self._optimistic: Optional[int] = None
        self._optimistic_since = 0.0
        self._server: Optional[asyncio.AbstractServer] = None
        self._tasks: List[asyncio.Task] = []
        self._metadata_ready = asyncio.Event()
        self._finished = asyncio.Event()
        self._stopping = False
        self._announced_complete = False

    # -- small accessors used by Peer -----------------------------------------

    def metadata_size(self) -> Optional[int]:
        return self._metadata_size

    def note_metadata_size(self, size: int) -> None:
        if self._metadata_size is None and 0 < size <= 16 * 1024 * 1024:
            self._metadata_size = size

    def has_metadata_piece(self, index: int) -> bool:
        return self._raw_metadata is not None or index in self._metadata_pieces

    def metadata_piece(self, index: int) -> Optional[bytes]:
        if self._raw_metadata is None:
            return None
        start = index * proto.METADATA_PIECE_SIZE
        if start >= len(self._raw_metadata):
            return None
        return self._raw_metadata[start : start + proto.METADATA_PIECE_SIZE]

    def account_download(self, count: int) -> None:
        self.downloaded += count

    def account_upload(self, count: int) -> None:
        self.uploaded += count

    def log(self, message: str) -> None:
        self.errors.append("%s  %s" % (time.strftime("%H:%M:%S"), message))

    def log_peer_error(self, peer: Peer, exc: BaseException) -> None:
        text = str(exc) or exc.__class__.__name__
        self.log("%s: %s" % (peer, text))

    # -- peer pool ------------------------------------------------------------

    def add_peer_address(self, address: Tuple[str, int]) -> None:
        host, port = address
        if not host or not (0 < port < 65536):
            return
        if address in self._queued or address in self._connecting or address in self._connected_addresses:
            return
        self._queued.add(address)
        self._candidates.append(address)

    def on_peer_ready(self, peer: Peer) -> None:
        self.peers[peer.key] = peer
        self._connected_addresses.add(peer.address)
        self._failures.pop(peer.address, None)
        if self.pieces is not None:
            self.pieces.add_peer(peer.key)

    def on_peer_gone(self, peer: Peer) -> None:
        self.peers.pop(peer.key, None)
        self._connected_addresses.discard(peer.address)
        if self.pieces is not None:
            self.pieces.remove_peer(peer.key)
        # Allow a retry later, with backoff.
        count = self._failures.get(peer.address, 0) + 1
        self._failures[peer.address] = count
        if count <= 4 and not peer.incoming:
            self._retry_at[peer.address] = time.monotonic() + PEER_RETRY_BASE * count

    def _connectable(self) -> Optional[Tuple[str, int]]:
        now = time.monotonic()
        for address, when in list(self._retry_at.items()):
            if when <= now:
                del self._retry_at[address]
                self.add_peer_address(address)
        while self._candidates:
            address = self._candidates.popleft()
            self._queued.discard(address)
            if address in self._connecting or address in self._connected_addresses:
                continue
            return address
        return None

    async def _connect_loop(self) -> None:
        while not self._stopping:
            await asyncio.sleep(CONNECT_INTERVAL)
            if self.paused:
                continue
            while len(self.peers) + len(self._connecting) < self.max_peers:
                address = self._connectable()
                if address is None:
                    break
                self._connecting.add(address)
                self._spawn(self._dial(address))

    async def _dial(self, address: Tuple[str, int]) -> None:
        host, port = address
        peer = Peer(self, host, port)
        try:
            await peer.run()
        finally:
            self._connecting.discard(address)

    # -- incoming connections -------------------------------------------------

    async def _start_listener(self) -> None:
        if self._listener is not None:
            self._listener.register(self)
            self.listen_port = self._listener.port
            return
        for candidate in range(self.listen_port, self.listen_port + 10):
            try:
                self._server = await asyncio.start_server(self._on_incoming, "0.0.0.0", candidate)
                self.listen_port = candidate
                return
            except OSError:
                continue
        self.log("could not bind a listening port; running outgoing-only")
        self.listen_port = 0

    async def _on_incoming(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        try:
            raw = await asyncio.wait_for(reader.readexactly(proto.HANDSHAKE_LENGTH), 15.0)
            reserved, info_hash, peer_id = proto.parse_handshake(raw)
            if info_hash != self.info_hash:
                writer.close()
                return
        except (OSError, asyncio.IncompleteReadError, asyncio.TimeoutError, proto.ProtocolError):
            writer.close()
            return
        await self.adopt_incoming(reader, writer, reserved, peer_id)

    async def adopt_incoming(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter,
                             reserved: bytes, peer_id: bytes) -> None:
        """Take over a connection whose handshake has already been read."""
        address = writer.get_extra_info("peername") or ("?", 0)
        if self.paused or self._stopping or peer_id == self.peer_id \
                or len(self.peers) >= self.max_peers + 10:
            try:
                writer.close()
            except OSError:
                pass
            return
        peer = Peer(self, str(address[0]), int(address[1]), reader=reader, writer=writer)
        peer.adopt_incoming_handshake(reserved, peer_id)
        await peer.run()

    # -- trackers -------------------------------------------------------------

    def _left(self) -> int:
        if self.pieces is None or self.meta is None:
            return 0
        return max(0, self.meta.total_length - self.pieces.bytes_verified)

    async def _announce(self, tracker: Tracker, event: str = "none") -> None:
        try:
            response = await tracker.announce(
                info_hash=self.info_hash, peer_id=self.peer_id, port=self.listen_port,
                uploaded=self.uploaded, downloaded=self.downloaded, left=self._left(),
                event=event,
            )
        except (TrackerError, OSError, asyncio.TimeoutError, struct.error) as exc:
            tracker.note_failure(exc if isinstance(exc, Exception) else TrackerError(str(exc)))
            self.log("tracker %s: %s" % (tracker.url, tracker.last_error))
            return
        tracker.note_success(response)
        for address in response.peers:
            self.add_peer_address(address)
        if response.warning:
            self.log("tracker %s: %s" % (tracker.url, response.warning))

    async def _tracker_loop(self) -> None:
        if not self.paused:
            await asyncio.gather(*(self._announce(t, "started") for t in self.trackers),
                                 return_exceptions=True)
        while not self._stopping:
            await asyncio.sleep(2.0)
            if self.paused:
                continue
            due = [t for t in self.trackers if t.is_due]
            if due:
                await asyncio.gather(*(self._announce(t) for t in due), return_exceptions=True)

    async def _announce_all(self, event: str) -> None:
        if not self.trackers:
            return
        try:
            await asyncio.wait_for(
                asyncio.gather(*(self._announce(t, event) for t in self.trackers), return_exceptions=True),
                timeout=10.0,
            )
        except asyncio.TimeoutError:
            pass

    # -- metadata (magnet) ----------------------------------------------------

    def on_metadata_piece(self, peer: Peer, index: int, data: bytes) -> None:
        if self._raw_metadata is not None or self._metadata_size is None:
            return
        count = (self._metadata_size + proto.METADATA_PIECE_SIZE - 1) // proto.METADATA_PIECE_SIZE
        if not (0 <= index < count):
            return
        expected = proto.METADATA_PIECE_SIZE
        if index == count - 1:
            expected = self._metadata_size - index * proto.METADATA_PIECE_SIZE
        if len(data) != expected:
            return
        self._metadata_pieces[index] = data
        if len(self._metadata_pieces) < count:
            return

        raw = b"".join(self._metadata_pieces[i] for i in range(count))
        if hashlib.sha1(raw).digest() != self.info_hash:
            self.log("metadata failed its hash check; starting over")
            self._metadata_pieces.clear()
            return
        try:
            meta = Metainfo.from_info_bytes(raw, [t.url for t in self.trackers])
        except (MetainfoError, ValueError) as exc:
            self.log("metadata is unusable: %s" % exc)
            self._metadata_pieces.clear()
            return
        self._raw_metadata = raw
        self.meta = meta
        self.display_name = meta.name
        self.log("got metadata for %s from %s" % (meta.name, peer))
        self._metadata_ready.set()

    async def _await_metadata(self) -> None:
        self.status_line = "fetching metadata from peers"
        await self._metadata_ready.wait()
        await self._prepare_storage()
        for peer in list(self.peers.values()):
            peer.on_metadata_ready()

    # -- storage --------------------------------------------------------------

    async def _prepare_storage(self) -> None:
        assert self.meta is not None
        loop = asyncio.get_event_loop()
        self.storage = Storage(self.meta, self.download_dir)
        await loop.run_in_executor(None, self.storage.allocate)

        have = None
        if self.verify_on_start and self.storage.any_data_on_disk():
            self.status_line = "checking existing files"

            def verify():
                return self.storage.verify()  # type: ignore[union-attr]

            have = await loop.run_in_executor(None, verify)
            done = sum(1 for ok in have if ok)
            if done:
                self.log("resuming: %d of %d pieces already on disk" % (done, self.meta.piece_count))

        self.pieces = PieceManager(self.meta, have)
        self.status_line = "downloading"
        if self.pieces.complete:
            self._on_download_complete()

    async def read_block(self, index: int, begin: int, length: int) -> Optional[bytes]:
        """Read a block for upload, caching whole pieces to keep the disk quiet."""
        if self.storage is None or self.pieces is None or not self.upload_enabled:
            return None
        if not self.pieces.have[index]:
            return None
        piece = self._piece_cache.get(index)
        if piece is None:
            try:
                piece = await asyncio.get_event_loop().run_in_executor(
                    None, self.storage.read_piece, index
                )
            except (OSError, ValueError) as exc:
                self.log("read error on piece %d: %s" % (index, exc))
                return None
            self._piece_cache[index] = piece
            while len(self._piece_cache) > PIECE_CACHE_SIZE:
                self._piece_cache.popitem(last=False)
        else:
            self._piece_cache.move_to_end(index)
        if begin + length > len(piece):
            return None
        return piece[begin : begin + length]

    # -- block / piece flow ---------------------------------------------------

    def on_block(self, peer: Peer, index: int, begin: int, block: bytes) -> None:
        if self.pieces is None:
            return
        completed, data = self.pieces.block_received(peer.key, index, begin, block)
        if not completed:
            return
        if data is None:
            self.log("piece %d failed its hash check; will retry" % index)
            return
        self._spawn(self._store_piece(index, data))

    async def _store_piece(self, index: int, data: bytes) -> None:
        if self.storage is None or self.pieces is None:
            return
        try:
            await asyncio.get_event_loop().run_in_executor(None, self.storage.write_piece, index, data)
        except (OSError, ValueError) as exc:
            self.log("write error on piece %d: %s" % (index, exc))
            self.pieces.have[index] = False
            return

        have_message = proto.msg_have(index)
        for peer in list(self.peers.values()):
            peer.send(have_message)
            peer.drop_pending(index)
            peer.update_interest()

        if self.pieces.complete:
            self._on_download_complete()

    def _on_download_complete(self) -> None:
        if self.completed_at is not None:
            return
        self.completed_at = time.monotonic()
        self.status_line = "seeding" if self.seed_after_complete else "complete"
        if not self._announced_complete:
            self._announced_complete = True
            self._spawn(self._announce_all("completed"))
        if self.storage is not None:
            self._spawn(asyncio.get_event_loop().run_in_executor(None, self.storage.flush))
        if not self.seed_after_complete:
            if self.stay_alive:
                self.pause(status="finished")
            else:
                self._finished.set()

    # -- choking --------------------------------------------------------------

    def consider_unchoking(self, peer: Peer) -> None:
        if not self.upload_enabled:
            return
        unchoked = sum(1 for other in self.peers.values() if not other.am_choking)
        if unchoked < MAX_UNCHOKED:
            peer.set_choking(False)

    async def _choke_loop(self) -> None:
        while not self._stopping:
            await asyncio.sleep(CHOKE_INTERVAL)
            if not self.upload_enabled:
                continue
            self._rechoke()

    def _rechoke(self) -> None:
        interested = [p for p in self.peers.values() if p.peer_interested and not p.closed]
        if self.completed_at is not None:
            # Seeding: favour whoever takes data fastest, so pieces spread.
            interested.sort(key=lambda p: p.bytes_uploaded, reverse=True)
        else:
            # Leeching: reciprocate with whoever feeds us fastest.
            interested.sort(key=lambda p: p.download_rate, reverse=True)

        keep = {p.key for p in interested[:MAX_UNCHOKED]}

        now = time.monotonic()
        if self._optimistic not in keep and now - self._optimistic_since >= OPTIMISTIC_INTERVAL:
            others = [p for p in interested[MAX_UNCHOKED:]]
            self._optimistic = random.choice(others).key if others else None
            self._optimistic_since = now
        if self._optimistic is not None:
            keep.add(self._optimistic)

        for peer in self.peers.values():
            peer.set_choking(peer.key not in keep)

    # -- rates ----------------------------------------------------------------

    async def _stats_loop(self) -> None:
        while not self._stopping:
            await asyncio.sleep(1.0)
            now = time.monotonic()
            self._rate_samples.append((now, self.downloaded, self.uploaded))
            if len(self._rate_samples) >= 2:
                first = self._rate_samples[0]
                elapsed = now - first[0]
                if elapsed > 0:
                    self.download_rate = (self.downloaded - first[1]) / elapsed
                    self.upload_rate = (self.uploaded - first[2]) / elapsed
            if self.pieces is not None:
                self.pieces.expire_requests()
                for peer in list(self.peers.values()):
                    peer.request_more()

    # -- status ---------------------------------------------------------------

    def status(self) -> Dict[str, Any]:
        total = self.meta.total_length if self.meta else 0
        done = self.pieces.bytes_verified if self.pieces else 0
        return {
            "name": self.display_name,
            "state": self.status_line,
            "total": total,
            "done": done,
            "progress": (done / total) if total else 0.0,
            "download_rate": self.download_rate,
            "upload_rate": self.upload_rate,
            "peers": len(self.peers),
            "seeds": sum(1 for p in self.peers.values()
                         if self.pieces and len(self.pieces.peer_pieces(p.key)) == self.pieces.meta.piece_count),
            "candidates": len(self._candidates) + len(self._retry_at),
            "downloaded": self.downloaded,
            "uploaded": self.uploaded,
            "pieces_done": self.pieces.pieces_done if self.pieces else 0,
            "piece_count": self.meta.piece_count if self.meta else 0,
            "trackers": [(t.url, t.last_peer_count, t.last_error) for t in self.trackers],
            "errors": list(self.errors),
            "elapsed": time.monotonic() - self.started_at,
            "complete": self.completed_at is not None,
            "paused": self.paused,
            "info_hash": self.info_hash.hex(),
            "listen_port": self.listen_port,
        }

    # -- lifecycle ------------------------------------------------------------

    def _spawn(self, coro) -> None:
        task = asyncio.ensure_future(coro)
        self._tasks.append(task)
        task.add_done_callback(lambda t: self._tasks.remove(t) if t in self._tasks else None)

    async def run(self) -> None:
        await self._start_listener()
        if self.meta is not None:
            await self._prepare_storage()

        loops = [
            asyncio.ensure_future(self._tracker_loop()),
            asyncio.ensure_future(self._connect_loop()),
            asyncio.ensure_future(self._choke_loop()),
            asyncio.ensure_future(self._stats_loop()),
        ]
        if self.meta is None:
            loops.append(asyncio.ensure_future(self._await_metadata()))

        try:
            await self._finished.wait()
        finally:
            self._stopping = True
            for task in loops:
                task.cancel()
            await self.shutdown()

    async def shutdown(self) -> None:
        self._stopping = True
        await self._announce_all("stopped")
        for peer in list(self.peers.values()):
            await peer.close()
        for task in list(self._tasks):
            task.cancel()
        if self._listener is not None:
            self._listener.unregister(self)
        if self._server is not None:
            self._server.close()
        if self.storage is not None:
            try:
                await asyncio.get_event_loop().run_in_executor(None, self.storage.close)
            except Exception:
                pass

    def pause(self, status: str = "paused") -> None:
        if self.paused:
            return
        self.paused = True
        self.status_line = status
        self._spawn(self._go_quiet())

    async def _go_quiet(self) -> None:
        await self._announce_all("stopped")
        for peer in list(self.peers.values()):
            await peer.close()
        self._candidates.clear()
        self._queued.clear()

    def resume(self) -> None:
        if not self.paused:
            return
        self.paused = False
        if self.meta is None:
            self.status_line = "fetching metadata from peers"
        elif self.completed_at is not None:
            self.status_line = "seeding" if self.seed_after_complete else "finished"
        else:
            self.status_line = "downloading"
        self._spawn(self._announce_all("started"))

    def stop(self) -> None:
        self._finished.set()


def parse_address(text: str) -> Optional[Tuple[str, int]]:
    """Parse host:port, including [v6]:port."""
    text = text.strip()
    if not text:
        return None
    if text.startswith("["):
        end = text.find("]")
        if end == -1:
            return None
        host = text[1:end]
        rest = text[end + 1 :]
        if not rest.startswith(":"):
            return None
        port_text = rest[1:]
    else:
        if text.count(":") != 1:
            return None
        host, _, port_text = text.partition(":")
    try:
        port = int(port_text)
    except ValueError:
        return None
    if not (0 < port < 65536) or not host:
        return None
    return (host, port)
