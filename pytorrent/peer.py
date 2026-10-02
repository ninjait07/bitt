"""One peer connection: handshake, state machine, download and upload."""

from __future__ import annotations

import asyncio
import struct
import time
from typing import Any, Dict, List, Optional, Set, Tuple

from . import protocol as proto
from .metainfo import BLOCK_SIZE

CONNECT_TIMEOUT = 12.0
HANDSHAKE_TIMEOUT = 15.0
IDLE_TIMEOUT = 150.0
KEEPALIVE_INTERVAL = 90.0

MIN_PIPELINE = 4
MAX_PIPELINE = 96
MAX_UPLOAD_QUEUE = 64
MAX_BLOCK_REQUEST = 128 * 1024  # refuse silly upload requests

_next_peer_key = 0


def _new_key() -> int:
    global _next_peer_key
    _next_peer_key += 1
    return _next_peer_key


class Peer:
    def __init__(self, session, host: str, port: int,
                 reader: Optional[asyncio.StreamReader] = None,
                 writer: Optional[asyncio.StreamWriter] = None) -> None:
        self.session = session
        self.host = host
        self.port = port
        self.key = _new_key()
        self.incoming = reader is not None

        self._reader = reader
        self._writer = writer
        self._send_queue: "asyncio.Queue[Optional[bytes]]" = asyncio.Queue(maxsize=256)
        self._upload_queue: "asyncio.Queue[Optional[Tuple[int, int, int]]]" = asyncio.Queue(
            maxsize=MAX_UPLOAD_QUEUE
        )

        self.am_choking = True
        self.am_interested = False
        self.peer_choking = True
        self.peer_interested = False

        self.peer_id: Optional[bytes] = None
        self.client_name = ""
        self.supports_extensions = False
        self.ut_metadata_id: Optional[int] = None
        self.metadata_size: Optional[int] = None

        self.pending: Dict[Tuple[int, int], int] = {}  # (index, begin) -> block length
        self.pipeline = 8
        self.bytes_downloaded = 0
        self.bytes_uploaded = 0
        self._window_bytes = 0
        self._window_started = time.monotonic()
        self.download_rate = 0.0
        self.last_message_at = time.monotonic()
        self.connected_at = 0.0

        self._closed = False
        self._tasks: List[asyncio.Task] = []
        self._sent_bitfield = False
        self._requested_metadata: Set[int] = set()
        # A magnet peer announces what it has before we know the piece count;
        # hold those announcements until the metadata arrives.
        self._deferred_bitfield: Optional[bytes] = None
        self._deferred_have: List[int] = []

    # -- identity -------------------------------------------------------------

    def __str__(self) -> str:
        who = self.client_name or (self.peer_id[:8].decode("ascii", "replace") if self.peer_id else "?")
        return "%s:%d (%s)" % (self.host, self.port, who)

    @property
    def address(self) -> Tuple[str, int]:
        return (self.host, self.port)

    # -- lifecycle ------------------------------------------------------------

    async def run(self) -> None:
        try:
            await self._connect()
            await self._exchange_handshakes()
            self.connected_at = time.monotonic()
            self.session.on_peer_ready(self)
            await self._after_handshake()

            self._tasks = [
                asyncio.ensure_future(self._sender_loop()),
                asyncio.ensure_future(self._upload_loop()),
                asyncio.ensure_future(self._tick_loop()),
            ]
            await self._receive_loop()
        except asyncio.CancelledError:
            raise
        except (OSError, asyncio.IncompleteReadError, asyncio.TimeoutError,
                proto.ProtocolError, ValueError) as exc:
            self.session.log_peer_error(self, exc)
        finally:
            await self.close()

    async def _connect(self) -> None:
        if self._reader is None:
            self._reader, self._writer = await asyncio.wait_for(
                asyncio.open_connection(self.host, self.port), CONNECT_TIMEOUT
            )

    async def _exchange_handshakes(self) -> None:
        assert self._reader is not None and self._writer is not None
        ours = proto.make_handshake(self.session.info_hash, self.session.peer_id)

        if self.incoming:
            # The listener already read and validated their handshake for us.
            self._writer.write(ours)
            await self._writer.drain()
        else:
            self._writer.write(ours)
            await self._writer.drain()
            raw = await asyncio.wait_for(
                self._reader.readexactly(proto.HANDSHAKE_LENGTH), HANDSHAKE_TIMEOUT
            )
            reserved, info_hash, peer_id = proto.parse_handshake(raw)
            if info_hash != self.session.info_hash:
                raise proto.ProtocolError("peer offered a different torrent")
            self.peer_id = peer_id
            self.supports_extensions = proto.supports_extensions(reserved)
            self.client_name = _client_name(peer_id)

        if self.peer_id == self.session.peer_id:
            raise proto.ProtocolError("connected to ourselves")

    def adopt_incoming_handshake(self, reserved: bytes, peer_id: bytes) -> None:
        self.peer_id = peer_id
        self.supports_extensions = proto.supports_extensions(reserved)
        self.client_name = _client_name(peer_id)

    async def _after_handshake(self) -> None:
        if self.supports_extensions:
            self.send(proto.extended_handshake_payload(
                self.session.metadata_size(), self.session.client_version,
                self.session.listen_port,
            ))
        if self.session.meta is not None:
            self._send_bitfield()

    def _send_bitfield(self) -> None:
        if self._sent_bitfield or self.session.pieces is None:
            return
        self._sent_bitfield = True
        if self.session.pieces.pieces_done:
            self.send(proto.msg_bitfield(self.session.pieces.bitfield_bytes()))

    async def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        for task in self._tasks:
            task.cancel()
        # Unblock the sender/upload loops if they are waiting on a queue.
        for queue in (self._send_queue, self._upload_queue):
            try:
                queue.put_nowait(None)
            except asyncio.QueueFull:
                pass
        if self._writer is not None:
            try:
                self._writer.close()
            except OSError:
                pass
        self.session.on_peer_gone(self)

    @property
    def closed(self) -> bool:
        return self._closed

    # -- sending --------------------------------------------------------------

    def send(self, data: bytes) -> None:
        if self._closed:
            return
        try:
            self._send_queue.put_nowait(data)
        except asyncio.QueueFull:
            # The peer is not draining; treat it as dead rather than buffering.
            asyncio.ensure_future(self.close())

    async def _sender_loop(self) -> None:
        assert self._writer is not None
        try:
            while not self._closed:
                data = await self._send_queue.get()
                if data is None:
                    return
                self._writer.write(data)
                await self._writer.drain()
        except (OSError, asyncio.CancelledError):
            pass
        except Exception as exc:  # pragma: no cover - defensive
            self.session.log_peer_error(self, exc)

    async def _tick_loop(self) -> None:
        try:
            while not self._closed:
                await asyncio.sleep(5.0)
                now = time.monotonic()
                if now - self.last_message_at > IDLE_TIMEOUT:
                    self.session.log_peer_error(self, TimeoutError("idle"))
                    await self.close()
                    return
                if now - self._window_started >= 1.0:
                    elapsed = now - self._window_started
                    self.download_rate = self._window_bytes / elapsed
                    self._window_bytes = 0
                    self._window_started = now
                self.send(proto.frame(None))  # keep-alive
                self.request_more()
        except asyncio.CancelledError:
            pass

    # -- receiving ------------------------------------------------------------

    async def _receive_loop(self) -> None:
        assert self._reader is not None
        while not self._closed:
            message_id, payload = await proto.read_message(self._reader)
            self.last_message_at = time.monotonic()
            if message_id is None:
                continue
            await self._handle(message_id, payload)

    async def _handle(self, message_id: int, payload: bytes) -> None:
        pieces = self.session.pieces

        if message_id == proto.CHOKE:
            self.peer_choking = True
            # Everything outstanding is void once choked.
            if pieces is not None:
                pieces.release_peer_requests(self.key)
            self.pending.clear()

        elif message_id == proto.UNCHOKE:
            self.peer_choking = False
            self.request_more()

        elif message_id == proto.INTERESTED:
            self.peer_interested = True
            self.session.consider_unchoking(self)

        elif message_id == proto.NOT_INTERESTED:
            self.peer_interested = False

        elif message_id == proto.HAVE:
            if len(payload) != 4:
                raise proto.ProtocolError("malformed have")
            (index,) = struct.unpack(">I", payload)
            if pieces is None:
                self._deferred_have.append(index)
            else:
                pieces.peer_has_piece(self.key, index)
                self.update_interest()
                self.request_more()

        elif message_id == proto.BITFIELD:
            if pieces is None:
                self._deferred_bitfield = payload
            else:
                indices = proto.bitfield_to_indices(payload, pieces.meta.piece_count)
                pieces.peer_has_bitfield(self.key, indices)
                self.update_interest()
                self.request_more()

        elif message_id == proto.REQUEST:
            if len(payload) != 12:
                raise proto.ProtocolError("malformed request")
            index, begin, length = struct.unpack(">III", payload)
            self._queue_upload(index, begin, length)

        elif message_id == proto.CANCEL:
            pass  # we serve requests promptly; nothing queued long enough to cancel

        elif message_id == proto.PIECE:
            if len(payload) < 8:
                raise proto.ProtocolError("malformed piece")
            index, begin = struct.unpack(">II", payload[:8])
            block = payload[8:]
            self._on_block(index, begin, block)

        elif message_id == proto.PORT:
            pass  # DHT node announcement; we do not run a DHT node

        elif message_id == proto.EXTENDED:
            await self._on_extended(payload)

    def _on_block(self, index: int, begin: int, block: bytes) -> None:
        self.pending.pop((index, begin), None)
        self.bytes_downloaded += len(block)
        self._window_bytes += len(block)
        self.session.account_download(len(block))
        self.session.on_block(self, index, begin, block)
        self.request_more()

    def update_interest(self) -> None:
        pieces = self.session.pieces
        if pieces is None:
            return
        wanted = pieces.peer_is_useful(self.key)
        if wanted and not self.am_interested:
            self.am_interested = True
            self.send(proto.frame(proto.INTERESTED))
        elif not wanted and self.am_interested:
            self.am_interested = False
            self.send(proto.frame(proto.NOT_INTERESTED))

    # -- download pipeline ----------------------------------------------------

    def request_more(self) -> None:
        pieces = self.session.pieces
        if self._closed or pieces is None or self.peer_choking or pieces.complete:
            return
        if not self.am_interested:
            self.update_interest()
            if not self.am_interested:
                return

        # Grow the pipeline with observed throughput (roughly one second of data).
        target = int(self.download_rate / BLOCK_SIZE) + MIN_PIPELINE
        self.pipeline = max(MIN_PIPELINE, min(MAX_PIPELINE, target))

        while len(self.pending) < self.pipeline:
            request = pieces.next_request(self.key)
            if request is None:
                break
            self.pending[(request.index, request.begin)] = request.length
            self.send(proto.msg_request(request.index, request.begin, request.length))

    def drop_pending(self, index: int) -> None:
        """Cancel outstanding requests for a piece we already completed."""
        stale = [key for key in self.pending if key[0] == index]
        for key in stale:
            length = self.pending.pop(key)
            self.send(proto.msg_cancel(index, key[1], length))

    # -- upload ---------------------------------------------------------------

    def set_choking(self, choking: bool) -> None:
        if choking == self.am_choking:
            return
        self.am_choking = choking
        self.send(proto.frame(proto.CHOKE if choking else proto.UNCHOKE))

    def _queue_upload(self, index: int, begin: int, length: int) -> None:
        if self.am_choking or self.session.pieces is None:
            return
        if length <= 0 or length > MAX_BLOCK_REQUEST:
            raise proto.ProtocolError("peer requested a %d-byte block" % length)
        if not (0 <= index < self.session.pieces.meta.piece_count) or not self.session.pieces.have[index]:
            return
        if begin + length > self.session.pieces.meta.piece_size(index):
            raise proto.ProtocolError("request runs past the end of piece %d" % index)
        try:
            self._upload_queue.put_nowait((index, begin, length))
        except asyncio.QueueFull:
            pass  # peer is flooding us; silently drop the surplus

    async def _upload_loop(self) -> None:
        try:
            while not self._closed:
                item = await self._upload_queue.get()
                if item is None:
                    return
                index, begin, length = item
                if self.am_choking:
                    continue
                data = await self.session.read_block(index, begin, length)
                if data is None:
                    continue
                self.send(proto.msg_piece(index, begin, data))
                self.bytes_uploaded += len(data)
                self.session.account_upload(len(data))
        except asyncio.CancelledError:
            pass
        except Exception as exc:  # pragma: no cover - defensive
            self.session.log_peer_error(self, exc)

    # -- extension protocol ---------------------------------------------------

    async def _on_extended(self, payload: bytes) -> None:
        if not payload:
            raise proto.ProtocolError("empty extended message")
        extension_id = payload[0]
        body = payload[1:]

        if extension_id == 0:
            self._on_extended_handshake(body)
            return

        # An id we told them to use: currently only ut_metadata (1).
        if extension_id == 1:
            await self._on_ut_metadata(body)

    def _on_extended_handshake(self, body: bytes) -> None:
        try:
            info = proto.bencode.decode(body)
        except Exception:
            raise proto.ProtocolError("malformed extended handshake")
        if not isinstance(info, dict):
            return
        mapping = info.get(b"m") or {}
        if isinstance(mapping, dict):
            raw_id = mapping.get(b"ut_metadata")
            self.ut_metadata_id = int(raw_id) if isinstance(raw_id, int) and raw_id > 0 else None
        size = info.get(b"metadata_size")
        if isinstance(size, int) and 0 < size <= 16 * 1024 * 1024:
            self.metadata_size = size
        version = info.get(b"v")
        if isinstance(version, bytes) and version:
            self.client_name = version.decode("utf-8", "replace")[:24]

        if self.session.meta is None:
            self.request_metadata()

    def request_metadata(self) -> None:
        """Ask for every metadata piece we have not already asked this peer for."""
        if self.ut_metadata_id is None or not self.metadata_size:
            return
        self.session.note_metadata_size(self.metadata_size)
        count = (self.metadata_size + proto.METADATA_PIECE_SIZE - 1) // proto.METADATA_PIECE_SIZE
        for piece in range(count):
            if piece in self._requested_metadata or self.session.has_metadata_piece(piece):
                continue
            self._requested_metadata.add(piece)
            self.send(proto.msg_extended(self.ut_metadata_id, proto.ut_metadata_request(piece)))

    async def _on_ut_metadata(self, body: bytes) -> None:
        try:
            header, trailing = proto.parse_ut_metadata(body)
        except Exception:
            raise proto.ProtocolError("malformed ut_metadata message")
        msg_type = header.get(b"msg_type")
        piece = header.get(b"piece")
        if not isinstance(piece, int):
            return

        if msg_type == proto.UT_DATA:
            total = header.get(b"total_size")
            if isinstance(total, int):
                self.session.note_metadata_size(total)
            self.session.on_metadata_piece(self, piece, trailing)

        elif msg_type == proto.UT_REQUEST:
            chunk = self.session.metadata_piece(piece)
            if chunk is None or self.ut_metadata_id is None:
                if self.ut_metadata_id is not None:
                    self.send(proto.msg_extended(self.ut_metadata_id, proto.ut_metadata_reject(piece)))
                return
            self.send(proto.msg_extended(
                self.ut_metadata_id,
                proto.ut_metadata_data(piece, self.session.metadata_size() or 0, chunk),
            ))

        elif msg_type == proto.UT_REJECT:
            self._requested_metadata.discard(piece)

    def on_metadata_ready(self) -> None:
        """Called once the torrent's info dict is known."""
        self._send_bitfield()
        pieces = self.session.pieces
        if pieces is None:
            return
        pieces.add_peer(self.key)
        if self._deferred_bitfield is not None:
            pieces.peer_has_bitfield(
                self.key, proto.bitfield_to_indices(self._deferred_bitfield, pieces.meta.piece_count)
            )
            self._deferred_bitfield = None
        for index in self._deferred_have:
            pieces.peer_has_piece(self.key, index)
        self._deferred_have.clear()
        self.update_interest()
        self.request_more()


_CLIENT_CODES = {
    b"AZ": "Azureus", b"BT": "BitTorrent", b"DE": "Deluge", b"LT": "libtorrent",
    b"lt": "libTorrent", b"qB": "qBittorrent", b"TR": "Transmission", b"UT": "uTorrent",
    b"UM": "uTorrent Mac", b"PY": "PyTorrent", b"WW": "WebTorrent", b"FD": "Free Download Mgr",
}


def _client_name(peer_id: Optional[bytes]) -> str:
    """Decode an Azureus-style peer id like -qB4550-xxxxxxxxxxxx."""
    if not peer_id or len(peer_id) < 8 or peer_id[0:1] != b"-":
        return ""
    code = peer_id[1:3]
    name = _CLIENT_CODES.get(code)
    if not name:
        return code.decode("ascii", "replace")
    version = peer_id[3:7].decode("ascii", "replace")
    return "%s %s" % (name, version)
