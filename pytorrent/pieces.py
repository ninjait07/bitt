"""Piece picking and block bookkeeping.

Strategy: rarest-first across the swarm, with a random tie-break so peers don't
all converge on the same piece; endgame duplication once the tail is in sight.
"""

from __future__ import annotations

import hashlib
import random
import time
from typing import Dict, List, NamedTuple, Optional, Sequence, Set, Tuple

from .metainfo import BLOCK_SIZE, Metainfo

PENDING = 0
REQUESTED = 1
DONE = 2

REQUEST_TIMEOUT = 30.0  # seconds before an unanswered block is offered again
ENDGAME_PIECES = 4      # start duplicating requests inside this many pieces


class BlockRequest(NamedTuple):
    index: int
    begin: int
    length: int


class _Block:
    __slots__ = ("begin", "length", "status", "requested_at", "peers")

    def __init__(self, begin: int, length: int) -> None:
        self.begin = begin
        self.length = length
        self.status = PENDING
        self.requested_at = 0.0
        self.peers: Set[int] = set()


class _Piece:
    __slots__ = ("index", "size", "blocks", "buffer", "received")

    def __init__(self, index: int, size: int) -> None:
        self.index = index
        self.size = size
        self.blocks: List[_Block] = []
        begin = 0
        while begin < size:
            length = min(BLOCK_SIZE, size - begin)
            self.blocks.append(_Block(begin, length))
            begin += length
        self.buffer = bytearray(size)
        self.received = 0

    def is_complete(self) -> bool:
        return self.received == self.size


class PieceManager:
    def __init__(self, meta: Metainfo, have: Optional[Sequence[bool]] = None) -> None:
        self.meta = meta
        self.have: List[bool] = list(have) if have is not None else [False] * meta.piece_count
        self.availability: List[int] = [0] * meta.piece_count
        self._active: Dict[int, _Piece] = {}
        self._peer_pieces: Dict[int, Set[int]] = {}
        self.bytes_verified = sum(meta.piece_size(i) for i, ok in enumerate(self.have) if ok)
        self.hash_failures = 0

    # -- swarm bookkeeping ----------------------------------------------------

    def add_peer(self, peer_id: int) -> None:
        self._peer_pieces.setdefault(peer_id, set())

    def remove_peer(self, peer_id: int) -> None:
        for index in self._peer_pieces.pop(peer_id, ()):  # decrement availability
            if 0 <= index < len(self.availability) and self.availability[index] > 0:
                self.availability[index] -= 1
        self.release_peer_requests(peer_id)

    def peer_has_piece(self, peer_id: int, index: int) -> None:
        if not (0 <= index < self.meta.piece_count):
            return
        owned = self._peer_pieces.setdefault(peer_id, set())
        if index not in owned:
            owned.add(index)
            self.availability[index] += 1

    def peer_has_bitfield(self, peer_id: int, indices: Sequence[int]) -> None:
        for index in indices:
            self.peer_has_piece(peer_id, index)

    def peer_pieces(self, peer_id: int) -> Set[int]:
        return self._peer_pieces.get(peer_id, set())

    def peer_is_useful(self, peer_id: int) -> bool:
        """Does this peer hold anything we still need?"""
        for index in self._peer_pieces.get(peer_id, ()):
            if not self.have[index]:
                return True
        return False

    # -- progress -------------------------------------------------------------

    @property
    def complete(self) -> bool:
        return all(self.have)

    @property
    def pieces_done(self) -> int:
        return sum(1 for ok in self.have if ok)

    @property
    def missing_pieces(self) -> int:
        return self.meta.piece_count - self.pieces_done

    def downloaded_bytes(self) -> int:
        """Verified bytes plus whatever is buffered in partial pieces."""
        return self.bytes_verified + sum(piece.received for piece in self._active.values())

    def bitfield_bytes(self) -> bytes:
        out = bytearray((self.meta.piece_count + 7) // 8)
        for index, ok in enumerate(self.have):
            if ok:
                out[index // 8] |= 0x80 >> (index % 8)
        return bytes(out)

    # -- picking --------------------------------------------------------------

    def expire_requests(self, now: Optional[float] = None) -> None:
        now = now if now is not None else time.monotonic()
        for piece in self._active.values():
            for block in piece.blocks:
                if block.status == REQUESTED and now - block.requested_at > REQUEST_TIMEOUT:
                    block.status = PENDING
                    block.peers.clear()

    def release_peer_requests(self, peer_id: int) -> None:
        """Hand back everything this peer had outstanding."""
        for piece in self._active.values():
            for block in piece.blocks:
                if peer_id in block.peers:
                    block.peers.discard(peer_id)
                    if block.status == REQUESTED and not block.peers:
                        block.status = PENDING

    def next_request(self, peer_id: int) -> Optional[BlockRequest]:
        """Pick the next block to ask this peer for, or None."""
        owned = self._peer_pieces.get(peer_id)
        if not owned:
            return None

        # Finish pieces already in flight before opening new ones.
        for index in sorted(self._active, key=lambda i: -self._piece_progress(i)):
            if index in owned and not self.have[index]:
                request = self._take_block(self._active[index], peer_id)
                if request is not None:
                    return request

        index = self._choose_new_piece(owned)
        if index is not None:
            piece = _Piece(index, self.meta.piece_size(index))
            self._active[index] = piece
            request = self._take_block(piece, peer_id)
            if request is not None:
                return request

        return self._endgame_request(peer_id, owned)

    def _piece_progress(self, index: int) -> int:
        piece = self._active.get(index)
        return piece.received if piece else 0

    def _take_block(self, piece: _Piece, peer_id: int) -> Optional[BlockRequest]:
        for block in piece.blocks:
            if block.status == PENDING:
                block.status = REQUESTED
                block.requested_at = time.monotonic()
                block.peers.add(peer_id)
                return BlockRequest(piece.index, block.begin, block.length)
        return None

    def _choose_new_piece(self, owned: Set[int]) -> Optional[int]:
        best_rarity = None
        candidates: List[int] = []
        for index in owned:
            if self.have[index] or index in self._active:
                continue
            rarity = self.availability[index]
            if best_rarity is None or rarity < best_rarity:
                best_rarity = rarity
                candidates = [index]
            elif rarity == best_rarity:
                candidates.append(index)
        if not candidates:
            return None
        return random.choice(candidates)

    def _endgame_request(self, peer_id: int, owned: Set[int]) -> Optional[BlockRequest]:
        """Near the end, re-ask other peers for blocks that are still in flight."""
        if self.missing_pieces > ENDGAME_PIECES:
            return None
        for index, piece in self._active.items():
            if index not in owned or self.have[index]:
                continue
            for block in piece.blocks:
                if block.status == REQUESTED and peer_id not in block.peers:
                    block.peers.add(peer_id)
                    return BlockRequest(index, block.begin, block.length)
        return None

    # -- receiving ------------------------------------------------------------

    def block_received(self, peer_id: int, index: int, begin: int, data: bytes) -> Tuple[bool, Optional[bytes]]:
        """Record a block.

        Returns (piece_completed, piece_data). piece_data is None unless the
        piece just completed AND its SHA-1 matched, so the caller can write it.
        """
        piece = self._active.get(index)
        if piece is None or self.have[index]:
            return False, None
        position = begin // BLOCK_SIZE
        if position >= len(piece.blocks):
            return False, None
        block = piece.blocks[position]
        if block.begin != begin or block.status == DONE:
            return False, None
        if len(data) != block.length:
            return False, None

        piece.buffer[begin : begin + len(data)] = data
        block.status = DONE
        block.peers.clear()
        piece.received += len(data)

        if not piece.is_complete():
            return False, None

        data_out = bytes(piece.buffer)
        del self._active[index]
        if hashlib.sha1(data_out).digest() != self.meta.piece_hashes[index]:
            self.hash_failures += 1
            return True, None  # completed, but corrupt: it will be picked again

        self.have[index] = True
        self.bytes_verified += piece.size
        return True, data_out

    def mark_have(self, index: int) -> None:
        if not self.have[index]:
            self.have[index] = True
            self.bytes_verified += self.meta.piece_size(index)
        self._active.pop(index, None)
