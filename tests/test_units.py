"""Unit tests for the pieces that do not need a network."""

import hashlib
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from pytorrent import bencode
from pytorrent.create import create_torrent, pick_piece_length
from pytorrent.metainfo import BLOCK_SIZE, Metainfo, MetainfoError, parse_magnet
from pytorrent.pieces import PieceManager
from pytorrent.protocol import bitfield_to_indices, make_handshake, parse_handshake, supports_extensions
from pytorrent.session import parse_address
from pytorrent.storage import Storage
from pytorrent.tracker import Tracker, TrackerError, _parse_http_response, _unpack_compact


class TestBencode(unittest.TestCase):
    def test_round_trip(self):
        for raw in [b"i42e", b"i-7e", b"i0e", b"4:spam", b"0:", b"le", b"de",
                    b"l4:spami3ee", b"d3:cow3:moo4:spam4:eggse",
                    b"d1:ad1:bl1:ci1eeee"]:
            self.assertEqual(bencode.encode(bencode.decode(raw)), raw)

    def test_keys_are_sorted_on_encode(self):
        self.assertEqual(bencode.encode({b"b": 1, b"a": 2}), b"d1:ai2e1:bi1ee")

    def test_rejects_malformed(self):
        for raw in [b"i03e", b"i-0e", b"ie", b"4:ab", b"l", b"d3:keye", b"", b"i1ex", b"01:a"]:
            with self.assertRaises(bencode.BencodeError):
                bencode.decode(raw)

    def test_decode_prefix_leaves_trailing_bytes(self):
        value, offset = bencode.decode_prefix(b"d1:ai1eeTRAILING")
        self.assertEqual(value, {b"a": 1})
        self.assertEqual(offset, len(b"d1:ai1ee"))


class TestMetainfo(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, True)

    def _torrent(self, data=b"x" * 70000, piece_length=16384):
        hashes = b"".join(hashlib.sha1(data[i:i + piece_length]).digest()
                          for i in range(0, len(data), piece_length))
        info = {b"name": b"f.bin", b"piece length": piece_length,
                b"pieces": hashes, b"length": len(data)}
        return Metainfo(info)

    def test_piece_sizes(self):
        meta = self._torrent()
        self.assertEqual(meta.piece_count, 5)
        self.assertEqual(meta.piece_size(0), 16384)
        self.assertEqual(meta.piece_size(4), 70000 - 4 * 16384)
        self.assertEqual(sum(meta.piece_size(i) for i in range(meta.piece_count)), 70000)

    def test_piece_count_mismatch_is_rejected(self):
        info = {b"name": b"f", b"piece length": 16384, b"pieces": b"\x00" * 20, b"length": 999999}
        with self.assertRaises(MetainfoError):
            Metainfo(info)

    def test_path_traversal_is_neutralised(self):
        info = {
            b"name": b"..", b"piece length": 16384, b"pieces": hashlib.sha1(b"a").digest(),
            b"files": [{b"length": 1, b"path": [b"..", b"..", b"etc", b"passwd"]}],
        }
        meta = Metainfo(info)
        self.assertNotIn("..", meta.name)
        self.assertEqual(meta.files[0].path, os.path.join("etc", "passwd"))

    def test_info_hash_survives_round_trip(self):
        raw = create_torrent(self._write_sample(), ["udp://t.example:80/a"])
        meta = Metainfo.from_bytes(raw)
        again = Metainfo.from_info_bytes(meta.raw_info)
        self.assertEqual(meta.info_hash, again.info_hash)

    def _write_sample(self):
        path = os.path.join(self.dir, "sample.bin")
        with open(path, "wb") as handle:
            handle.write(os.urandom(100000))
        return path

    def test_magnet_parsing(self):
        link = parse_magnet(
            "magnet:?xt=urn:btih:c9e15763f722f23e98a29decdfae341b98d53056"
            "&dn=Name+Here&tr=udp%3A%2F%2Ft.example%3A1337%2Fannounce&x.pe=1.2.3.4:6881"
        )
        self.assertEqual(link.info_hash.hex(), "c9e15763f722f23e98a29decdfae341b98d53056")
        self.assertEqual(link.display_name, "Name Here")
        self.assertEqual(link.trackers, ["udp://t.example:1337/announce"])
        self.assertEqual(link.peers, ["1.2.3.4:6881"])

    def test_magnet_rejects_v2_and_garbage(self):
        for uri in ["magnet:?dn=x", "magnet:?xt=urn:btmh:1220abcd", "http://example/x"]:
            with self.assertRaises(MetainfoError):
                parse_magnet(uri)

    def test_create_multi_file_torrent(self):
        root = os.path.join(self.dir, "pack", "inner")
        os.makedirs(root)
        with open(os.path.join(self.dir, "pack", "one.bin"), "wb") as handle:
            handle.write(os.urandom(40000))
        with open(os.path.join(root, "two.bin"), "wb") as handle:
            handle.write(os.urandom(5000))
        meta = Metainfo.from_bytes(create_torrent(os.path.join(self.dir, "pack")))
        self.assertTrue(meta.is_multi_file())
        self.assertEqual(meta.total_length, 45000)
        self.assertEqual([f.path for f in meta.files], ["one.bin", os.path.join("inner", "two.bin")])
        self.assertEqual(meta.files[1].offset, 40000)

    def test_piece_length_scales(self):
        self.assertEqual(pick_piece_length(1000), 16384)
        self.assertGreater(pick_piece_length(10 ** 10), pick_piece_length(10 ** 8))
        self.assertLessEqual(pick_piece_length(10 ** 13), 16 * 1024 * 1024)


class TestStorage(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, True)
        source = os.path.join(self.dir, "pack", "deep")
        os.makedirs(source)
        self.payload = {}
        for name, size in [("a.bin", 30000), (os.path.join("deep", "b.bin"), 25000)]:
            data = os.urandom(size)
            self.payload[name] = data
            with open(os.path.join(self.dir, "pack", name), "wb") as handle:
                handle.write(data)
        self.meta = Metainfo.from_bytes(create_torrent(os.path.join(self.dir, "pack"), piece_length=16384))
        self.stream = b"".join(self.payload[f.path] for f in self.meta.files)

    def test_write_read_across_file_boundaries(self):
        out = os.path.join(self.dir, "out")
        os.makedirs(out)
        with Storage(self.meta, out) as storage:
            storage.allocate()
            for index in range(self.meta.piece_count):
                start = index * self.meta.piece_length
                storage.write_piece(index, self.stream[start:start + self.meta.piece_size(index)])
            self.assertEqual(storage.read(0, self.meta.total_length), self.stream)
            self.assertEqual(storage.read_block(1, 100, 50), self.stream[16384 + 100:16384 + 150])
            self.assertTrue(all(storage.verify()))

        for name, data in self.payload.items():
            with open(os.path.join(out, "pack", name), "rb") as handle:
                self.assertEqual(handle.read(), data)

    def test_verify_flags_missing_data(self):
        out = os.path.join(self.dir, "empty")
        os.makedirs(out)
        with Storage(self.meta, out) as storage:
            storage.allocate()
            self.assertFalse(any(storage.verify()))

    def test_refuses_range_outside_torrent(self):
        out = os.path.join(self.dir, "range")
        os.makedirs(out)
        with Storage(self.meta, out) as storage:
            storage.allocate()
            with self.assertRaises(ValueError):
                storage.read(self.meta.total_length, 10)


class TestPieceManager(unittest.TestCase):
    def setUp(self):
        self.data = os.urandom(200000)
        piece_length = 32768
        hashes = b"".join(hashlib.sha1(self.data[i:i + piece_length]).digest()
                          for i in range(0, len(self.data), piece_length))
        self.meta = Metainfo({b"name": b"x.bin", b"piece length": piece_length,
                              b"pieces": hashes, b"length": len(self.data)})

    def _feed(self, manager, peer, request):
        start = request.index * self.meta.piece_length + request.begin
        return manager.block_received(peer, request.index, request.begin,
                                      self.data[start:start + request.length])

    def test_full_download(self):
        manager = PieceManager(self.meta)
        manager.add_peer(1)
        manager.peer_has_bitfield(1, range(self.meta.piece_count))
        while not manager.complete:
            request = manager.next_request(1)
            self.assertIsNotNone(request)
            self._feed(manager, 1, request)
        self.assertEqual(manager.downloaded_bytes(), len(self.data))
        self.assertEqual(manager.bitfield_bytes(), b"\xfe")  # 7 pieces, top bits set

    def test_bad_data_fails_the_hash_and_is_retried(self):
        manager = PieceManager(self.meta)
        manager.add_peer(1)
        manager.peer_has_bitfield(1, range(self.meta.piece_count))
        first = manager.next_request(1)
        for _ in range(self.meta.block_count(first.index)):
            request = first if _ == 0 else manager.next_request(1)
            manager.block_received(1, request.index, request.begin, b"\x00" * request.length)
        self.assertEqual(manager.hash_failures, 1)
        self.assertFalse(manager.have[first.index])
        self.assertIsNotNone(manager.next_request(1))  # offered again

    def test_rarest_first(self):
        manager = PieceManager(self.meta)
        for peer in (1, 2, 3):
            manager.add_peer(peer)
        manager.peer_has_bitfield(1, range(self.meta.piece_count))
        manager.peer_has_bitfield(2, [0, 1, 2, 3, 4, 5])  # piece 6 is rarest
        manager.peer_has_bitfield(3, [0, 1, 2, 3, 4, 5])
        self.assertEqual(manager.next_request(1).index, self.meta.piece_count - 1)

    def test_dropped_peer_releases_its_requests(self):
        manager = PieceManager(self.meta)
        manager.add_peer(1)
        manager.peer_has_bitfield(1, range(self.meta.piece_count))
        request = manager.next_request(1)
        manager.remove_peer(1)
        self.assertEqual(manager.availability[request.index], 0)
        manager.add_peer(2)
        manager.peer_has_bitfield(2, range(self.meta.piece_count))
        self.assertEqual(manager.next_request(2), request)

    def test_peer_with_nothing_we_need_is_not_useful(self):
        manager = PieceManager(self.meta, have=[True] * self.meta.piece_count)
        manager.add_peer(1)
        manager.peer_has_bitfield(1, [0, 1])
        self.assertFalse(manager.peer_is_useful(1))
        self.assertIsNone(manager.next_request(1))

    def test_block_sizes_cover_the_piece(self):
        manager = PieceManager(self.meta)
        manager.add_peer(1)
        last = self.meta.piece_count - 1
        manager.peer_has_bitfield(1, [last])
        total = 0
        while True:
            request = manager.next_request(1)
            if request is None:
                break
            self.assertLessEqual(request.length, BLOCK_SIZE)
            total += request.length
            self._feed(manager, 1, request)
        self.assertEqual(total, self.meta.piece_size(last))


class TestProtocol(unittest.TestCase):
    def test_handshake(self):
        raw = make_handshake(b"H" * 20, b"P" * 20)
        self.assertEqual(len(raw), 68)
        reserved, info_hash, peer_id = parse_handshake(raw)
        self.assertTrue(supports_extensions(reserved))
        self.assertEqual(info_hash, b"H" * 20)
        self.assertEqual(peer_id, b"P" * 20)

    def test_bitfield_ignores_padding_bits(self):
        self.assertEqual(bitfield_to_indices(bytes([0b11000000, 0b11111111]), 10), [0, 1, 8, 9])


class TestTracker(unittest.TestCase):
    def test_compact_peers(self):
        raw = b"\x01\x02\x03\x04\x1a\xe1" + b"\x0a\x00\x00\x01\xc8\xd5"
        self.assertEqual(_unpack_compact(raw, 4), [("1.2.3.4", 6881), ("10.0.0.1", 51413)])

    def test_failure_reason_raises(self):
        with self.assertRaises(TrackerError):
            _parse_http_response(b"d14:failure reason9:not founde")

    def test_dictionary_peers(self):
        body = b"d8:intervali900e5:peersld2:ip9:127.0.0.14:porti6881eeee"
        response = _parse_http_response(body)
        self.assertEqual(response.peers, [("127.0.0.1", 6881)])
        self.assertEqual(response.interval, 900)

    def test_unsupported_scheme(self):
        with self.assertRaises(TrackerError):
            Tracker("ftp://example.org/announce")


class TestAddresses(unittest.TestCase):
    def test_parse_address(self):
        self.assertEqual(parse_address("1.2.3.4:6881"), ("1.2.3.4", 6881))
        self.assertEqual(parse_address("[::1]:6881"), ("::1", 6881))
        for bad in ["", "nope", "h:0", "h:99999", "[::1]6881", "a:b:c"]:
            self.assertIsNone(parse_address(bad))


if __name__ == "__main__":
    unittest.main(verbosity=2)
