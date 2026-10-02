"""Bencode encoder/decoder (BEP 3).

Decoding keeps dict keys as bytes and never coerces values to str: a torrent's
`info` dict must survive a decode/encode round-trip byte-for-byte, otherwise the
info-hash changes.
"""

from __future__ import annotations

from typing import Any, Dict, List, Tuple


class BencodeError(ValueError):
    pass


def decode(data: bytes) -> Any:
    """Decode a complete bencoded value. Trailing garbage is an error."""
    value, index = _decode_from(data, 0)
    if index != len(data):
        raise BencodeError("trailing data after bencoded value at %d" % index)
    return value


def decode_prefix(data: bytes, start: int = 0) -> Tuple[Any, int]:
    """Decode one value and return (value, index just past it)."""
    return _decode_from(data, start)


def _decode_from(data: bytes, i: int) -> Tuple[Any, int]:
    if i >= len(data):
        raise BencodeError("unexpected end of data")
    char = data[i : i + 1]
    if char == b"i":
        return _decode_int(data, i)
    if char == b"l":
        return _decode_list(data, i)
    if char == b"d":
        return _decode_dict(data, i)
    if char.isdigit():
        return _decode_bytes(data, i)
    raise BencodeError("invalid token %r at %d" % (char, i))


def _decode_int(data: bytes, i: int) -> Tuple[int, int]:
    end = data.find(b"e", i)
    if end == -1:
        raise BencodeError("unterminated integer at %d" % i)
    raw = data[i + 1 : end]
    if raw in (b"", b"-") or raw.startswith(b"-0") or (raw.startswith(b"0") and raw != b"0"):
        raise BencodeError("malformed integer %r at %d" % (raw, i))
    try:
        return int(raw), end + 1
    except ValueError:
        raise BencodeError("malformed integer %r at %d" % (raw, i))


def _decode_bytes(data: bytes, i: int) -> Tuple[bytes, int]:
    sep = data.find(b":", i)
    if sep == -1:
        raise BencodeError("unterminated string length at %d" % i)
    raw_len = data[i:sep]
    if not raw_len.isdigit() or (raw_len.startswith(b"0") and raw_len != b"0"):
        raise BencodeError("malformed string length %r at %d" % (raw_len, i))
    length = int(raw_len)
    start = sep + 1
    end = start + length
    if end > len(data):
        raise BencodeError("string at %d runs past end of data" % i)
    return data[start:end], end


def _decode_list(data: bytes, i: int) -> Tuple[List[Any], int]:
    out: List[Any] = []
    i += 1
    while True:
        if i >= len(data):
            raise BencodeError("unterminated list")
        if data[i : i + 1] == b"e":
            return out, i + 1
        value, i = _decode_from(data, i)
        out.append(value)


def _decode_dict(data: bytes, i: int) -> Tuple[Dict[bytes, Any], int]:
    out: Dict[bytes, Any] = {}
    i += 1
    while True:
        if i >= len(data):
            raise BencodeError("unterminated dict")
        if data[i : i + 1] == b"e":
            return out, i + 1
        key, i = _decode_from(data, i)
        if not isinstance(key, bytes):
            raise BencodeError("dict key must be a string")
        value, i = _decode_from(data, i)
        out[key] = value


def encode(value: Any) -> bytes:
    chunks: List[bytes] = []
    _encode_into(value, chunks)
    return b"".join(chunks)


def _encode_into(value: Any, out: List[bytes]) -> None:
    if isinstance(value, bool):
        # bool before int: bencode has no boolean type.
        out.append(b"i1e" if value else b"i0e")
    elif isinstance(value, int):
        out.append(b"i%de" % value)
    elif isinstance(value, bytes):
        out.append(b"%d:" % len(value))
        out.append(value)
    elif isinstance(value, str):
        raw = value.encode("utf-8")
        out.append(b"%d:" % len(raw))
        out.append(raw)
    elif isinstance(value, (list, tuple)):
        out.append(b"l")
        for item in value:
            _encode_into(item, out)
        out.append(b"e")
    elif isinstance(value, dict):
        out.append(b"d")
        # Keys must be sorted as raw byte strings.
        items = []
        for key, item in value.items():
            raw_key = key.encode("utf-8") if isinstance(key, str) else key
            if not isinstance(raw_key, bytes):
                raise BencodeError("dict key must be bytes or str, got %r" % type(key))
            items.append((raw_key, item))
        items.sort(key=lambda kv: kv[0])
        for raw_key, item in items:
            _encode_into(raw_key, out)
            _encode_into(item, out)
        out.append(b"e")
    else:
        raise BencodeError("cannot bencode %r" % type(value))
