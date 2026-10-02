"""Integration tests: real sockets, real peer protocol, on loopback."""

import asyncio
import hashlib
import os
import random
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from pytorrent.create import create_torrent
from pytorrent.metainfo import Metainfo, parse_magnet
from pytorrent.session import Session

PORT = random.randint(30000, 50000)


def next_port():
    global PORT
    PORT += 1
    return PORT


def digest_tree(root):
    """Map every file under root to its sha1, so two trees can be compared."""
    out = {}
    for base, _, names in os.walk(root):
        for name in sorted(names):
            full = os.path.join(base, name)
            with open(full, "rb") as handle:
                out[os.path.relpath(full, root)] = hashlib.sha1(handle.read()).hexdigest()
    return out


class SwarmTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self.loop)
        self.addCleanup(self.loop.close)

    def make_payload(self, name="payload", sizes=((400000, "movie.bin"), (90000, "sub/notes.dat"))):
        root = os.path.join(self.dir, "origin", name)
        for size, relative in sizes:
            full = os.path.join(root, relative)
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, "wb") as handle:
                handle.write(os.urandom(size))
        raw = create_torrent(root, piece_length=16384)
        torrent_path = os.path.join(self.dir, name + ".torrent")
        with open(torrent_path, "wb") as handle:
            handle.write(raw)
        return Metainfo.from_bytes(raw), os.path.join(self.dir, "origin"), root

    def fresh_dir(self, name):
        path = os.path.join(self.dir, name)
        os.makedirs(path, exist_ok=True)
        return path

    async def _drive(self, leechers, seeders, timeout=60.0):
        tasks = [asyncio.ensure_future(s.run()) for s in seeders]
        await asyncio.sleep(0.4)
        tasks += [asyncio.ensure_future(s.run()) for s in leechers]
        deadline = self.loop.time() + timeout
        try:
            while self.loop.time() < deadline:
                await asyncio.sleep(0.1)
                if all(s.status()["complete"] for s in leechers):
                    return True
            return False
        finally:
            for session in leechers + seeders:
                session.stop()
            await asyncio.sleep(0.3)
            for session in leechers + seeders:
                await session.shutdown()
            for task in tasks:
                task.cancel()
            await asyncio.sleep(0.1)

    # -- tests ---------------------------------------------------------------

    def test_torrent_file_transfer(self):
        meta, origin, root = self.make_payload()
        seed_port = next_port()
        seeder = Session(meta, origin, listen_port=seed_port, seed=True)
        target = self.fresh_dir("leech")
        leecher = Session(meta, target, listen_port=next_port(),
                          extra_peers=[("127.0.0.1", seed_port)])

        ok = self.loop.run_until_complete(self._drive([leecher], [seeder]))
        self.assertTrue(ok, "download did not finish: %s" % leecher.status())
        self.assertEqual(digest_tree(root), digest_tree(os.path.join(target, meta.name)))
        self.assertGreater(seeder.uploaded, 0, "seeder never uploaded")

    def test_single_file_transfer(self):
        meta, origin, root = self.make_payload("solo", sizes=((250000, "solo.bin"),))
        # create_torrent on a directory makes it multi-file; that is fine here,
        # this case exercises a payload made of one file.
        seed_port = next_port()
        seeder = Session(meta, origin, listen_port=seed_port, seed=True)
        target = self.fresh_dir("solo_out")
        leecher = Session(meta, target, listen_port=next_port(),
                          extra_peers=[("127.0.0.1", seed_port)])
        self.assertTrue(self.loop.run_until_complete(self._drive([leecher], [seeder])))
        self.assertEqual(digest_tree(root), digest_tree(os.path.join(target, meta.name)))

    def test_magnet_fetches_metadata_from_peers(self):
        meta, origin, root = self.make_payload("magnetic")
        seed_port = next_port()
        seeder = Session(meta, origin, listen_port=seed_port, seed=True)
        target = self.fresh_dir("magnet_out")
        link = parse_magnet("magnet:?xt=urn:btih:" + meta.info_hash.hex())
        leecher = Session(link, target, listen_port=next_port(),
                          extra_peers=[("127.0.0.1", seed_port)])

        self.assertTrue(self.loop.run_until_complete(self._drive([leecher], [seeder])))
        self.assertIsNotNone(leecher.meta)
        self.assertEqual(leecher.meta.info_hash, meta.info_hash)
        self.assertEqual(digest_tree(root), digest_tree(os.path.join(target, meta.name)))

    def test_leecher_relays_to_another_leecher(self):
        """C connects only to B, so B must upload what it is still downloading."""
        meta, origin, root = self.make_payload("relay")
        seed_port, middle_port = next_port(), next_port()
        seeder = Session(meta, origin, listen_port=seed_port, seed=True)
        middle_dir = self.fresh_dir("middle")
        middle = Session(meta, middle_dir, listen_port=middle_port, seed=True,
                         extra_peers=[("127.0.0.1", seed_port)])
        tail_dir = self.fresh_dir("tail")
        tail = Session(meta, tail_dir, listen_port=next_port(),
                       extra_peers=[("127.0.0.1", middle_port)])

        ok = self.loop.run_until_complete(self._drive([tail], [seeder, middle], timeout=90))
        self.assertTrue(ok, "relayed download did not finish: %s" % tail.status())
        self.assertEqual(digest_tree(root), digest_tree(os.path.join(tail_dir, meta.name)))
        self.assertGreater(middle.uploaded, 0, "middle peer never relayed any data")

    def test_resume_after_partial_data(self):
        meta, origin, root = self.make_payload("resumable")
        target = self.fresh_dir("resume_out")

        # Copy the payload, then wipe the tail of the big file.
        shutil.copytree(root, os.path.join(target, meta.name))
        damaged = os.path.join(target, meta.name, "movie.bin")
        size = os.path.getsize(damaged)
        with open(damaged, "r+b") as handle:
            handle.seek(size // 2)
            handle.write(b"\x00" * (size - size // 2))

        seed_port = next_port()
        seeder = Session(meta, origin, listen_port=seed_port, seed=True)
        leecher = Session(meta, target, listen_port=next_port(),
                          extra_peers=[("127.0.0.1", seed_port)])

        self.assertTrue(self.loop.run_until_complete(self._drive([leecher], [seeder])))
        self.assertEqual(digest_tree(root), digest_tree(os.path.join(target, meta.name)))
        # Only the damaged half should have crossed the wire.
        self.assertLess(leecher.downloaded, meta.total_length * 0.85)

    def test_wrong_info_hash_is_refused(self):
        meta, origin, _ = self.make_payload("guarded")
        other, _, _ = self.make_payload("stranger")
        seed_port = next_port()
        seeder = Session(meta, origin, listen_port=seed_port, seed=True)
        intruder = Session(other, self.fresh_dir("intruder"), listen_port=next_port(),
                           extra_peers=[("127.0.0.1", seed_port)])

        async def scenario():
            task = asyncio.ensure_future(seeder.run())
            await asyncio.sleep(0.4)
            task2 = asyncio.ensure_future(intruder.run())
            await asyncio.sleep(2.0)
            connected = len(seeder.peers)
            seeder.stop(); intruder.stop()
            await asyncio.sleep(0.3)
            await seeder.shutdown(); await intruder.shutdown()
            task.cancel(); task2.cancel()
            await asyncio.sleep(0.1)
            return connected

        self.assertEqual(self.loop.run_until_complete(scenario()), 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
