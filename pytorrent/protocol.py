"""The BitTorrent peer wire protocol (BEP 3), plus BEP 10 / BEP 9 for magnets."""

from __future__ import annotations

import asyncio
import struct
from typing import Any, Dict, List, Optional

from . import bencode

PROTOCOL = b"BitTorrent protocol"
HANDSHAKE_LENGTH = 68
METADATA_PIECE_SIZE = 16 * 1024

# Message ids
CHOKE = 0
UNCHOKE = 1
INTERESTED = 2
NOT_INTERESTED = 3
HAVE = 4
BITFIELD = 5
REQUEST = 6
PIECE = 7
CANCEL = 8
PORT = 9
EXTENDED = 20

MESSAGE_NAMES = {
    CHOKE: "choke", UNCHOKE: "unchoke", INTERESTED: "interested",
    NOT_INTERESTED: "not interested", HAVE: "have", BITFIELD: "bitfield",
    REQUEST: "request", PIECE: "piece", CANCEL: "cancel", PORT: "port",
    EXTENDED: "extended",
}

# Reserved-byte feature bits
EXTENSION_BIT = (5, 0x10)   # BEP 10 extension protocol
FAST_BIT = (7, 0x04)        # BEP 6 (we advertise nothing; listed for clarity)

# ut_metadata sub-message types (BEP 9)
UT_REQUEST = 0
UT_DATA = 1
UT_REJECT = 2

MAX_MESSAGE_LENGTH = 1 << 20  # 1 MiB: refuse absurd frames from hostile peers


class ProtocolError(Exception):
    pass


def make_handshake(info_hash: bytes, peer_id: bytes) -> bytes:
    reserved = bytearray(8)
    reserved[EXTENSION_BIT[0]] |= EXTENSION_BIT[1]
    return struct.pack(">B19s8s20s20s", len(PROTOCOL), PROTOCOL, bytes(reserved), info_hash, peer_id)


def parse_handshake(data: bytes):
    """Return (reserved, info_hash, peer_id)."""
    if len(data) != HANDSHAKE_LENGTH:
        raise ProtocolError("handshake must be %d bytes, got %d" % (HANDSHAKE_LENGTH, len(data)))
    length, protocol, reserved, info_hash, peer_id = struct.unpack(">B19s8s20s20s", data)
    if length != 19 or protocol != PROTOCOL:
        raise ProtocolError("peer is not speaking BitTorrent")
    return reserved, info_hash, peer_id


def supports_extensions(reserved: bytes) -> bool:
    return bool(reserved[EXTENSION_BIT[0]] & EXTENSION_BIT[1])


# -- message framing ----------------------------------------------------------

def frame(message_id: Optional[int], payload: bytes = b"") -> bytes:
    if message_id is None:  # keep-alive
        return b"\x00\x00\x00\x00"
    return struct.pack(">IB", len(payload) + 1, message_id) + payload


def msg_have(index: int) -> bytes:
    return frame(HAVE, struct.pack(">I", index))


def msg_bitfield(bits: bytes) -> bytes:
    return frame(BITFIELD, bits)


def msg_request(index: int, begin: int, length: int) -> bytes:
    return frame(REQUEST, struct.pack(">III", index, begin, length))


def msg_cancel(index: int, begin: int, length: int) -> bytes:
    return frame(CANCEL, struct.pack(">III", index, begin, length))


def msg_piece(index: int, begin: int, block: bytes) -> bytes:
    return frame(PIECE, struct.pack(">II", index, begin) + block)


def msg_extended(extension_id: int, payload: bytes) -> bytes:
    return frame(EXTENDED, bytes([extension_id]) + payload)


def bitfield_to_indices(bits: bytes, piece_count: int) -> List[int]:
    out: List[int] = []
    for byte_index, byte in enumerate(bits):
        if not byte:
            continue
        for bit in range(8):
            if byte & (0x80 >> bit):
                index = byte_index * 8 + bit
                if index < piece_count:
                    out.append(index)
    return out


# -- BEP 10 / BEP 9 -----------------------------------------------------------

def extended_handshake_payload(metadata_size: Optional[int], client_version: bytes,
                               listen_port: Optional[int] = None) -> bytes:
    body: Dict[bytes, Any] = {
        b"m": {b"ut_metadata": 1},
        b"v": client_version,
        b"reqq": 250,
    }
    if metadata_size:
        body[b"metadata_size"] = metadata_size
    if listen_port:
        body[b"p"] = listen_port
    return msg_extended(0, bencode.encode(body))


def ut_metadata_request(piece: int) -> bytes:
    return bencode.encode({b"msg_type": UT_REQUEST, b"piece": piece})


def ut_metadata_data(piece: int, total_size: int, chunk: bytes) -> bytes:
    header = bencode.encode({b"msg_type": UT_DATA, b"piece": piece, b"total_size": total_size})
    return header + chunk


def ut_metadata_reject(piece: int) -> bytes:
    return bencode.encode({b"msg_type": UT_REJECT, b"piece": piece})


def parse_ut_metadata(payload: bytes):
    """Return (header_dict, trailing_bytes)."""
    header, offset = bencode.decode_prefix(payload, 0)
    if not isinstance(header, dict):
        raise ProtocolError("ut_metadata payload is not a dictionary")
    return header, payload[offset:]


async def read_message(reader: asyncio.StreamReader):
    """Read one framed message. Returns (id, payload); id is None for keep-alive."""
    header = await reader.readexactly(4)
    (length,) = struct.unpack(">I", header)
    if length == 0:
        return None, b""
    if length > MAX_MESSAGE_LENGTH:
        raise ProtocolError("peer announced a %d-byte message" % length)
    body = await reader.readexactly(length)
    return body[0], body[1:]
