"""One incoming-connection port shared by every torrent in a session group.

A client that runs several torrents should not open a port per torrent: peers
announce one port to the tracker, and the info-hash in the handshake says which
torrent the caller wants.
"""

from __future__ import annotations

import asyncio
from typing import Dict, Optional

from . import protocol as proto


class PeerListener:
    def __init__(self, port: int = 6881, attempts: int = 10) -> None:
        self.requested_port = port
        self.attempts = attempts
        self.port = 0
        self._server: Optional[asyncio.AbstractServer] = None
        self._sessions: Dict[bytes, object] = {}

    async def start(self) -> bool:
        for candidate in range(self.requested_port, self.requested_port + self.attempts):
            try:
                self._server = await asyncio.start_server(self._handle, "0.0.0.0", candidate)
            except OSError:
                continue
            self.port = candidate
            return True
        self.port = 0
        return False

    def register(self, session) -> None:
        self._sessions[session.info_hash] = session

    def unregister(self, session) -> None:
        if self._sessions.get(session.info_hash) is session:
            del self._sessions[session.info_hash]

    async def _handle(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        try:
            raw = await asyncio.wait_for(reader.readexactly(proto.HANDSHAKE_LENGTH), 15.0)
            reserved, info_hash, peer_id = proto.parse_handshake(raw)
        except (OSError, asyncio.IncompleteReadError, asyncio.TimeoutError, proto.ProtocolError):
            _close(writer)
            return

        session = self._sessions.get(info_hash)
        if session is None:
            _close(writer)
            return
        await session.adopt_incoming(reader, writer, reserved, peer_id)

    async def close(self) -> None:
        self._sessions.clear()
        if self._server is not None:
            self._server.close()
            try:
                await self._server.wait_closed()
            except Exception:
                pass
            self._server = None


def _close(writer: asyncio.StreamWriter) -> None:
    try:
        writer.close()
    except OSError:
        pass
