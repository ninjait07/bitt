"""Disk layout: map the torrent's flat byte stream onto real files.

All methods here block; the session calls them from a worker thread.
"""

from __future__ import annotations

import hashlib
import os
import threading
from collections import OrderedDict
from typing import Callable, Iterator, List, Optional, Tuple

from .metainfo import Metainfo

MAX_OPEN_FILES = 64


class Storage:
    def __init__(self, meta: Metainfo, download_dir: str) -> None:
        self.meta = meta
        self.download_dir = os.path.abspath(download_dir)
        # A multi-file torrent gets its own directory; a single-file one does not.
        self.root = os.path.join(self.download_dir, meta.name) if meta.is_multi_file() else self.download_dir
        self._handles: "OrderedDict[str, object]" = OrderedDict()
        self._lock = threading.RLock()
        self._closed = False

    # -- paths ----------------------------------------------------------------

    def path_for(self, relative: str) -> str:
        full = os.path.normpath(os.path.join(self.root, relative))
        root_prefix = os.path.join(os.path.normpath(self.root), "")
        if full != os.path.normpath(self.root) and not full.startswith(root_prefix):
            raise ValueError("file path escapes the download directory: %r" % relative)
        return full

    def allocate(self) -> None:
        """Create every file at its final size (sparse; APFS costs nothing for holes)."""
        with self._lock:
            for entry in self.meta.files:
                full = self.path_for(entry.path)
                os.makedirs(os.path.dirname(full) or ".", exist_ok=True)
                if not os.path.exists(full):
                    with open(full, "wb"):
                        pass
                current = os.path.getsize(full)
                if current < entry.length:
                    with open(full, "r+b") as handle:
                        handle.truncate(entry.length)

    def existing_bytes(self) -> int:
        total = 0
        for entry in self.meta.files:
            try:
                total += min(os.path.getsize(self.path_for(entry.path)), entry.length)
            except OSError:
                pass
        return total

    def any_data_on_disk(self) -> bool:
        return self.existing_bytes() > 0

    # -- byte-range mapping ---------------------------------------------------

    def _segments(self, offset: int, length: int) -> Iterator[Tuple[str, int, int, int]]:
        """Yield (path, offset_in_file, offset_in_buffer, length) covering the range."""
        if offset < 0 or length < 0 or offset + length > self.meta.total_length:
            raise ValueError("range %d+%d is outside the torrent" % (offset, length))
        buffer_pos = 0
        remaining = length
        for entry in self.meta.files:
            if remaining <= 0:
                break
            file_end = entry.offset + entry.length
            start = offset + buffer_pos
            if start >= file_end or entry.length == 0:
                continue
            in_file = start - entry.offset
            take = min(entry.length - in_file, remaining)
            yield entry.path, in_file, buffer_pos, take
            buffer_pos += take
            remaining -= take
        if remaining:
            raise ValueError("could not map %d trailing bytes" % remaining)

    def _handle(self, relative: str):
        with self._lock:
            if self._closed:
                raise ValueError("storage is closed")
            handle = self._handles.get(relative)
            if handle is None:
                full = self.path_for(relative)
                os.makedirs(os.path.dirname(full) or ".", exist_ok=True)
                if not os.path.exists(full):
                    with open(full, "wb"):
                        pass
                handle = open(full, "r+b")
                self._handles[relative] = handle
                while len(self._handles) > MAX_OPEN_FILES:
                    _, stale = self._handles.popitem(last=False)
                    try:
                        stale.close()  # type: ignore[union-attr]
                    except OSError:
                        pass
            else:
                self._handles.move_to_end(relative)
            return handle

    # -- I/O ------------------------------------------------------------------

    def write(self, offset: int, data: bytes) -> None:
        with self._lock:
            for relative, in_file, in_buffer, take in self._segments(offset, len(data)):
                handle = self._handle(relative)
                handle.seek(in_file)  # type: ignore[union-attr]
                handle.write(data[in_buffer : in_buffer + take])  # type: ignore[union-attr]

    def read(self, offset: int, length: int) -> bytes:
        out = bytearray(length)
        with self._lock:
            for relative, in_file, in_buffer, take in self._segments(offset, length):
                handle = self._handle(relative)
                handle.seek(in_file)  # type: ignore[union-attr]
                chunk = handle.read(take)  # type: ignore[union-attr]
                if len(chunk) < take:
                    # Short read: the file is smaller than it should be.
                    chunk = chunk + b"\x00" * (take - len(chunk))
                out[in_buffer : in_buffer + take] = chunk
        return bytes(out)

    def write_piece(self, index: int, data: bytes) -> None:
        self.write(index * self.meta.piece_length, data)

    def read_piece(self, index: int) -> bytes:
        return self.read(index * self.meta.piece_length, self.meta.piece_size(index))

    def read_block(self, index: int, begin: int, length: int) -> bytes:
        return self.read(index * self.meta.piece_length + begin, length)

    def flush(self) -> None:
        with self._lock:
            for handle in self._handles.values():
                try:
                    handle.flush()  # type: ignore[union-attr]
                except OSError:
                    pass

    def close(self) -> None:
        with self._lock:
            self._closed = True
            for handle in self._handles.values():
                try:
                    handle.close()  # type: ignore[union-attr]
                except OSError:
                    pass
            self._handles.clear()

    # -- resume ---------------------------------------------------------------

    def verify(self, progress: Optional[Callable[[int, int], None]] = None) -> List[bool]:
        """Hash every piece already on disk. Returns a have-bitfield."""
        have = [False] * self.meta.piece_count
        for index in range(self.meta.piece_count):
            try:
                data = self.read_piece(index)
            except (OSError, ValueError):
                data = b""
            if len(data) == self.meta.piece_size(index):
                have[index] = hashlib.sha1(data).digest() == self.meta.piece_hashes[index]
            if progress is not None:
                progress(index + 1, self.meta.piece_count)
        return have

    def __enter__(self) -> "Storage":
        return self

    def __exit__(self, *exc) -> None:
        self.close()
