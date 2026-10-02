"""Multi-torrent manager plus a line-based JSON protocol.

The macOS app runs this as a child process and talks to it over stdin/stdout:
one JSON object per line in each direction. Every request may carry an "id",
which comes back on the reply.
"""

from __future__ import annotations

import asyncio
import json
import os
import shutil
import sys
import time
import traceback
from typing import Any, Dict, List, Optional

from .create import create_torrent
from .listener import PeerListener
from .metainfo import MagnetLink, Metainfo, MetainfoError, parse_magnet
from .session import Session

STATE_VERSION = 1
TICK = 1.0

DEFAULT_SETTINGS = {
    "download_dir": os.path.expanduser("~/Downloads"),
    "port": 6881,
    "max_peers": 60,
    "seed_after_complete": True,
    "max_active": 8,
}


def support_dir() -> str:
    base = os.path.expanduser("~/Library/Application Support/Swarm")
    os.makedirs(os.path.join(base, "torrents"), exist_ok=True)
    return base


class ManagerError(Exception):
    pass


class Entry:
    """One torrent the manager is looking after."""

    def __init__(self, info_hash: str, source: str, download_dir: str,
                 session: Session, task: "asyncio.Future") -> None:
        self.info_hash = info_hash
        self.source = source           # magnet URI, or a path under torrents/
        self.download_dir = download_dir
        self.session = session
        self.task = task
        self.saved_metadata = False
        self.was_complete = session.status()["complete"]


class TorrentManager:
    def __init__(self, base_dir: Optional[str] = None,
                 settings: Optional[Dict[str, Any]] = None) -> None:
        self.base_dir = base_dir or support_dir()
        self.torrent_dir = os.path.join(self.base_dir, "torrents")
        self.state_path = os.path.join(self.base_dir, "state.json")
        os.makedirs(self.torrent_dir, exist_ok=True)

        self.settings = dict(DEFAULT_SETTINGS)
        self.settings.update(settings or {})
        self.entries: Dict[str, Entry] = {}
        self.listener = PeerListener(int(self.settings["port"]))
        self.events: "asyncio.Queue[Dict[str, Any]]" = asyncio.Queue()
        self._started = False

    # -- lifecycle ------------------------------------------------------------

    async def start(self) -> None:
        if self._started:
            return
        self._started = True
        bound = await self.listener.start()
        if not bound:
            self.emit({"event": "warning",
                       "message": "could not open a listening port; downloads still work"})
        await self.restore()

    def emit(self, payload: Dict[str, Any]) -> None:
        try:
            self.events.put_nowait(payload)
        except asyncio.QueueFull:
            pass

    async def shutdown(self) -> None:
        self.save()
        for entry in list(self.entries.values()):
            entry.session.stop()
        await asyncio.sleep(0.2)
        for entry in list(self.entries.values()):
            await entry.session.shutdown()
            entry.task.cancel()
        await self.listener.close()

    # -- adding ---------------------------------------------------------------

    def _resolve(self, source: str):
        """Turn a user-supplied string into a Metainfo or MagnetLink."""
        source = source.strip()
        if source.lower().startswith("magnet:"):
            return parse_magnet(source), source
        if source.lower().startswith(("http://", "https://")):
            import urllib.request

            request = urllib.request.Request(source, headers={"User-Agent": "Swarm/1.0"})
            with urllib.request.urlopen(request, timeout=30) as response:
                return Metainfo.from_bytes(response.read(8 * 1024 * 1024)), source
        if source.startswith("file://"):
            import urllib.parse

            source = urllib.parse.unquote(source[len("file://") :])
        if not os.path.exists(source):
            raise ManagerError("no such file: %s" % source)
        return Metainfo.from_file(source), source

    async def add(self, source: str, download_dir: Optional[str] = None,
                  paused: bool = False) -> Dict[str, Any]:
        loop = asyncio.get_event_loop()
        parsed, original = await loop.run_in_executor(None, self._resolve, source)

        info_hash = parsed.info_hash.hex()
        if info_hash in self.entries:
            raise ManagerError("already in the list: %s" % self.entries[info_hash].session.display_name)

        target = os.path.abspath(os.path.expanduser(download_dir or self.settings["download_dir"]))
        os.makedirs(target, exist_ok=True)

        stored = original
        if isinstance(parsed, Metainfo):
            stored = self._store_torrent(parsed)

        session = Session(
            parsed, target,
            listen_port=self.listener.port or int(self.settings["port"]),
            max_peers=int(self.settings["max_peers"]),
            seed=bool(self.settings["seed_after_complete"]),
            listener=self.listener,
            stay_alive=True,
            paused=paused,
        )
        task = asyncio.ensure_future(self._run_session(info_hash, session))
        self.entries[info_hash] = Entry(info_hash, stored, target, session, task)
        self.save()
        self.emit({"event": "added", "hash": info_hash, "name": session.display_name})
        return {"hash": info_hash, "name": session.display_name}

    async def _run_session(self, info_hash: str, session: Session) -> None:
        try:
            await session.run()
        except asyncio.CancelledError:
            raise
        except Exception:
            self.emit({"event": "error", "hash": info_hash,
                       "message": traceback.format_exc(limit=3)})

    def _store_torrent(self, meta: Metainfo) -> str:
        """Keep our own copy so the list survives a restart."""
        path = os.path.join(self.torrent_dir, meta.info_hash.hex() + ".torrent")
        if not os.path.exists(path):
            with open(path, "wb") as handle:
                handle.write(meta.to_torrent_bytes())
        return path

    # -- control --------------------------------------------------------------

    def _entry(self, info_hash: str) -> Entry:
        entry = self.entries.get(info_hash)
        if entry is None:
            raise ManagerError("unknown torrent: %s" % info_hash)
        return entry

    def pause(self, info_hash: str) -> None:
        self._entry(info_hash).session.pause()
        self.save()

    def resume(self, info_hash: str) -> None:
        self._entry(info_hash).session.resume()
        self.save()

    def pause_all(self) -> None:
        for entry in self.entries.values():
            entry.session.pause()
        self.save()

    def resume_all(self) -> None:
        for entry in self.entries.values():
            entry.session.resume()
        self.save()

    async def remove(self, info_hash: str, delete_data: bool = False) -> None:
        entry = self._entry(info_hash)
        session = entry.session
        session.stop()
        await asyncio.sleep(0.15)
        await session.shutdown()
        entry.task.cancel()
        del self.entries[info_hash]

        stored = os.path.join(self.torrent_dir, info_hash + ".torrent")
        if os.path.exists(stored):
            try:
                os.remove(stored)
            except OSError:
                pass

        if delete_data and session.storage is not None and session.meta is not None:
            self._delete_payload(session)
        self.save()

    def _delete_payload(self, session: Session) -> None:
        meta, storage = session.meta, session.storage
        if meta is None or storage is None:
            return
        try:
            if meta.is_multi_file():
                root = storage.root
                # Only remove a directory we created inside the download folder.
                if os.path.isdir(root) and os.path.dirname(root) == storage.download_dir:
                    shutil.rmtree(root, ignore_errors=True)
            else:
                for entry in meta.files:
                    path = storage.path_for(entry.path)
                    if os.path.isfile(path):
                        os.remove(path)
        except (OSError, ValueError):
            pass

    def update_settings(self, changes: Dict[str, Any]) -> Dict[str, Any]:
        for key in ("download_dir", "port", "max_peers", "seed_after_complete", "max_active"):
            if key not in changes:
                continue
            value = changes[key]
            if key == "download_dir":
                self.settings[key] = os.path.abspath(os.path.expanduser(str(value)))
                os.makedirs(self.settings[key], exist_ok=True)
            elif key == "seed_after_complete":
                self.settings[key] = bool(value)
                for entry in self.entries.values():
                    entry.session.seed_after_complete = bool(value)
            else:
                self.settings[key] = max(1, int(value))
                if key == "max_peers":
                    for entry in self.entries.values():
                        entry.session.max_peers = self.settings[key]
        self.save()
        return self.settings

    # -- reporting ------------------------------------------------------------

    def snapshot(self) -> List[Dict[str, Any]]:
        out = []
        for info_hash, entry in self.entries.items():
            status = entry.session.status()
            status["hash"] = info_hash
            status["download_dir"] = entry.download_dir
            status["added_at"] = entry.session.added_at
            status["has_metadata"] = entry.session.meta is not None
            out.append(status)
        out.sort(key=lambda s: s["added_at"])
        return out

    def details(self, info_hash: str) -> Dict[str, Any]:
        entry = self._entry(info_hash)
        session = entry.session
        meta = session.meta
        files = []
        if meta is not None:
            done_bytes = _bytes_per_file(session)
            for index, item in enumerate(meta.files):
                files.append({
                    "path": item.path,
                    "length": item.length,
                    "done": done_bytes[index],
                })
        peers = []
        for peer in list(session.peers.values())[:200]:
            peers.append({
                "address": "%s:%d" % (peer.host, peer.port),
                "client": peer.client_name or "unknown",
                "downloaded": peer.bytes_downloaded,
                "uploaded": peer.bytes_uploaded,
                "rate": peer.download_rate,
                "choked": peer.peer_choking,
                "incoming": peer.incoming,
            })
        peers.sort(key=lambda p: p["downloaded"], reverse=True)
        return {
            "hash": info_hash,
            "name": session.display_name,
            "download_dir": entry.download_dir,
            "save_path": session.storage.root if session.storage else entry.download_dir,
            "files": files,
            "peers": peers,
            "trackers": [
                {"url": url, "peers": count, "error": error}
                for url, count, error in session.status()["trackers"]
            ],
            "log": list(session.errors)[-30:],
            "piece_count": meta.piece_count if meta else 0,
            "piece_length": meta.piece_length if meta else 0,
            "total": meta.total_length if meta else 0,
            "is_private": bool(meta.private) if meta else False,
        }

    # -- persistence ----------------------------------------------------------

    def save(self) -> None:
        payload = {
            "version": STATE_VERSION,
            "settings": self.settings,
            "torrents": [
                {
                    "hash": entry.info_hash,
                    "source": entry.source,
                    "dir": entry.download_dir,
                    "paused": entry.session.paused,
                    "added_at": entry.session.added_at,
                }
                for entry in self.entries.values()
            ],
        }
        temporary = self.state_path + ".tmp"
        try:
            with open(temporary, "w") as handle:
                json.dump(payload, handle, indent=1)
            os.replace(temporary, self.state_path)
        except OSError:
            pass

    async def restore(self) -> None:
        if not os.path.exists(self.state_path):
            return
        try:
            with open(self.state_path) as handle:
                payload = json.load(handle)
        except (OSError, ValueError):
            return

        stored_settings = payload.get("settings") or {}
        for key in DEFAULT_SETTINGS:
            if key in stored_settings:
                self.settings[key] = stored_settings[key]

        for item in payload.get("torrents") or []:
            source = item.get("source")
            if not source:
                continue
            try:
                await self.add(source, item.get("dir"), bool(item.get("paused")))
            except (ManagerError, MetainfoError, OSError, ValueError) as exc:
                self.emit({"event": "warning",
                           "message": "could not restore %s: %s" % (source, exc)})

    # -- periodic work --------------------------------------------------------

    async def tick_forever(self) -> None:
        while True:
            await asyncio.sleep(TICK)
            self._cache_new_metadata()
            self._notice_completions()
            self.emit({"event": "torrents", "torrents": self.snapshot()})

    def _cache_new_metadata(self) -> None:
        """Once a magnet resolves, write the .torrent so restarts are instant."""
        for entry in self.entries.values():
            if entry.saved_metadata or entry.session.meta is None:
                continue
            if entry.source.startswith("magnet:"):
                entry.source = self._store_torrent(entry.session.meta)
                self.save()
            entry.saved_metadata = True

    def _notice_completions(self) -> None:
        for entry in self.entries.values():
            complete = entry.session.status()["complete"]
            if complete and not entry.was_complete:
                self.emit({"event": "finished", "hash": entry.info_hash,
                           "name": entry.session.display_name,
                           "path": entry.session.storage.root if entry.session.storage else ""})
                self.save()
            entry.was_complete = complete


# -- JSON line protocol -------------------------------------------------------

class JSONProtocol:
    def __init__(self, manager: TorrentManager) -> None:
        self.manager = manager
        self.running = True

    def write(self, payload: Dict[str, Any]) -> None:
        try:
            sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
            sys.stdout.flush()
        except (OSError, ValueError):
            self.running = False

    async def handle(self, line: str) -> None:
        try:
            message = json.loads(line)
        except ValueError:
            return
        if not isinstance(message, dict):
            return
        request_id = message.get("id")
        command = message.get("cmd")
        try:
            result = await self.dispatch(command, message)
            if request_id is not None:
                self.write({"id": request_id, "ok": True, "result": result})
        except (ManagerError, MetainfoError, OSError, ValueError) as exc:
            if request_id is not None:
                self.write({"id": request_id, "ok": False, "error": str(exc)})
        except Exception as exc:  # pragma: no cover - defensive
            if request_id is not None:
                self.write({"id": request_id, "ok": False, "error": repr(exc)})

    async def dispatch(self, command: str, message: Dict[str, Any]) -> Any:
        manager = self.manager
        if command == "add":
            return await manager.add(message["source"], message.get("dir"),
                                     bool(message.get("paused")))
        if command == "remove":
            await manager.remove(message["hash"], bool(message.get("delete_data")))
            return {}
        if command == "pause":
            manager.pause(message["hash"])
            return {}
        if command == "resume":
            manager.resume(message["hash"])
            return {}
        if command == "pause_all":
            manager.pause_all()
            return {}
        if command == "resume_all":
            manager.resume_all()
            return {}
        if command == "list":
            return {"torrents": manager.snapshot()}
        if command == "details":
            return manager.details(message["hash"])
        if command == "settings":
            return manager.update_settings(message.get("values") or {})
        if command == "get_settings":
            return manager.settings
        if command == "create":
            raw = await asyncio.get_event_loop().run_in_executor(
                None, create_torrent, message["path"], message.get("trackers") or []
            )
            out = message["output"]
            with open(out, "wb") as handle:
                handle.write(raw)
            return {"path": out}
        if command == "quit":
            self.running = False
            return {}
        raise ManagerError("unknown command: %r" % command)

    async def pump_events(self) -> None:
        while self.running:
            payload = await self.manager.events.get()
            self.write(payload)

    async def read_stdin(self) -> None:
        loop = asyncio.get_event_loop()
        reader = asyncio.StreamReader()
        await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(reader), sys.stdin)
        while self.running:
            line = await reader.readline()
            if not line:  # the app went away
                self.running = False
                break
            await self.handle(line.decode("utf-8", "replace").strip())


async def serve(base_dir: Optional[str] = None) -> None:
    manager = TorrentManager(base_dir)
    protocol = JSONProtocol(manager)
    await manager.start()
    protocol.write({
        "event": "ready",
        "port": manager.listener.port,
        "settings": manager.settings,
        "torrents": manager.snapshot(),
    })
    tasks = [
        asyncio.ensure_future(protocol.pump_events()),
        asyncio.ensure_future(manager.tick_forever()),
        asyncio.ensure_future(protocol.read_stdin()),
    ]
    try:
        while protocol.running:
            await asyncio.sleep(0.2)
    finally:
        for task in tasks:
            task.cancel()
        await manager.shutdown()


def _bytes_per_file(session: Session) -> List[int]:
    """How much of each file is covered by verified pieces."""
    meta, pieces = session.meta, session.pieces
    if meta is None or pieces is None:
        return []
    totals = [0] * len(meta.files)
    for index, ok in enumerate(pieces.have):
        if not ok:
            continue
        start = index * meta.piece_length
        end = start + meta.piece_size(index)
        for position, item in enumerate(meta.files):
            overlap = min(end, item.offset + item.length) - max(start, item.offset)
            if overlap > 0:
                totals[position] += overlap
    return totals


def main(base_dir: Optional[str] = None) -> int:
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    try:
        loop.run_until_complete(serve(base_dir))
    except KeyboardInterrupt:
        pass
    finally:
        loop.close()
    return 0
