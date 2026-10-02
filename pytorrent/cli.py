"""Command line interface."""

from __future__ import annotations

import argparse
import asyncio
import os
import shutil
import signal
import sys
import time
from typing import List, Optional

from . import __version__
from .create import create_torrent, magnet_for
from .metainfo import MagnetLink, Metainfo, MetainfoError, parse_magnet
from .session import Session, parse_address

IS_TTY = sys.stdout.isatty()


# -- formatting ---------------------------------------------------------------

def human_bytes(count: float) -> str:
    step = 1024.0
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if abs(count) < step or unit == "TiB":
            if unit == "B":
                return "%d B" % count
            return "%.1f %s" % (count, unit)
        count /= step
    return "%.1f TiB" % count


def human_rate(rate: float) -> str:
    return human_bytes(rate) + "/s"


def human_time(seconds: float) -> str:
    if seconds < 0 or seconds != seconds or seconds == float("inf"):
        return "--"
    seconds = int(seconds)
    if seconds < 60:
        return "%ds" % seconds
    if seconds < 3600:
        return "%dm %02ds" % (seconds // 60, seconds % 60)
    if seconds < 86400:
        return "%dh %02dm" % (seconds // 3600, (seconds % 3600) // 60)
    return "%dd %dh" % (seconds // 86400, (seconds % 86400) // 3600)


def bar(fraction: float, width: int) -> str:
    fraction = max(0.0, min(1.0, fraction))
    filled = int(fraction * width)
    partial = ""
    if filled < width:
        eighths = int((fraction * width - filled) * 8)
        partial = " ▏▎▍▌▋▊▉"[eighths] if eighths else " "
    return "█" * filled + partial + " " * max(0, width - filled - len(partial))


class Display:
    """Redraws a small status block in place."""

    def __init__(self, enabled: bool = True) -> None:
        self.enabled = enabled and IS_TTY
        self._lines_drawn = 0

    def render(self, status: dict) -> None:
        if not self.enabled:
            return
        width = max(48, min(shutil.get_terminal_size((92, 24)).columns, 120))
        total = status["total"]
        done = status["done"]
        rate = status["download_rate"]
        eta = ((total - done) / rate) if (rate > 1 and total and done < total) else float("inf")

        name = status["name"]
        if len(name) > width - 2:
            name = name[: width - 5] + "..."

        lines: List[str] = []
        lines.append("\033[1m%s\033[0m" % name)
        if total:
            lines.append("  [%s] %5.1f%%  %s / %s" % (
                bar(status["progress"], width - 34),
                status["progress"] * 100,
                human_bytes(done), human_bytes(total),
            ))
        else:
            lines.append("  %s" % status["state"])
        lines.append("  ↓ %-11s ↑ %-11s  peers %d (%d seeds, %d known)  %s" % (
            human_rate(rate), human_rate(status["upload_rate"]),
            status["peers"], status["seeds"], status["candidates"],
            status["state"],
        ))
        lines.append("  pieces %d/%d   up %s   elapsed %s   eta %s" % (
            status["pieces_done"], status["piece_count"],
            human_bytes(status["uploaded"]),
            human_time(status["elapsed"]),
            human_time(eta),
        ))
        for message in status["errors"][-3:]:
            lines.append("  \033[2m%s\033[0m" % message[: width - 4])

        out = []
        if self._lines_drawn:
            out.append("\033[%dA" % self._lines_drawn)
        for line in lines:
            out.append("\033[2K" + line + "\n")
        # Clear any rows left over from a taller previous frame.
        for _ in range(max(0, self._lines_drawn - len(lines))):
            out.append("\033[2K\n")
        extra = max(0, self._lines_drawn - len(lines))
        if extra:
            out.append("\033[%dA" % extra)
        self._lines_drawn = len(lines)
        sys.stdout.write("".join(out))
        sys.stdout.flush()

    def finish(self) -> None:
        if self.enabled:
            sys.stdout.write("\n")
            sys.stdout.flush()


# -- source loading -----------------------------------------------------------

def load_source(source: str):
    """Return a Metainfo or a MagnetLink for a path, magnet URI or http(s) URL."""
    if source.lower().startswith("magnet:"):
        return parse_magnet(source)
    if source.lower().startswith(("http://", "https://")):
        import urllib.request

        request = urllib.request.Request(source, headers={"User-Agent": "pytorrent/%s" % __version__})
        with urllib.request.urlopen(request, timeout=30) as response:
            return Metainfo.from_bytes(response.read(8 * 1024 * 1024))
    if not os.path.exists(source):
        raise MetainfoError("no such file: %s" % source)
    return Metainfo.from_file(source)


def describe(meta: Metainfo) -> str:
    lines = [
        "name:       %s" % meta.name,
        "info hash:  %s" % meta.info_hash.hex(),
        "size:       %s (%d bytes)" % (human_bytes(meta.total_length), meta.total_length),
        "pieces:     %d x %s" % (meta.piece_count, human_bytes(meta.piece_length)),
        "private:    %s" % ("yes" if meta.private else "no"),
        "files:      %d" % len(meta.files),
    ]
    for entry in meta.files[:40]:
        lines.append("   %10s  %s" % (human_bytes(entry.length), entry.path))
    if len(meta.files) > 40:
        lines.append("   ... and %d more" % (len(meta.files) - 40))
    if meta.trackers:
        lines.append("trackers:")
        for url in meta.trackers[:20]:
            lines.append("   %s" % url)
    lines.append("magnet:     %s" % magnet_for(meta))
    return "\n".join(lines)


# -- commands -----------------------------------------------------------------

async def run_download(args: argparse.Namespace) -> int:
    source = load_source(args.source)

    if args.dry_run:
        if isinstance(source, Metainfo):
            print(describe(source))
        else:
            print("magnet for %s (%s)" % (source.display_name or "?", source.info_hash.hex()))
            print("metadata is only available from peers; run without --dry-run to fetch it")
        return 0

    extra_peers = []
    for text in args.peer or []:
        address = parse_address(text)
        if address is None:
            print("ignoring bad --peer %r" % text, file=sys.stderr)
        else:
            extra_peers.append(address)

    session = Session(
        source,
        args.output,
        listen_port=args.port,
        max_peers=args.max_peers,
        extra_trackers=args.tracker or [],
        extra_peers=extra_peers,
        seed=args.seed,
        verify=not args.no_verify,
        upload_enabled=not args.no_upload,
    )

    display = Display(enabled=not args.quiet)
    loop = asyncio.get_event_loop()
    interrupts = {"count": 0}

    def on_interrupt() -> None:
        interrupts["count"] += 1
        if interrupts["count"] == 1:
            session.status_line = "stopping (press Ctrl-C again to force)"
            session.stop()
        else:
            raise KeyboardInterrupt

    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, on_interrupt)
        except (NotImplementedError, RuntimeError):
            pass

    async def draw() -> None:
        while True:
            display.render(session.status())
            await asyncio.sleep(0.5)

    drawer = asyncio.ensure_future(draw())
    try:
        await session.run()
    finally:
        drawer.cancel()
        display.render(session.status())
        display.finish()

    status = session.status()
    if status["complete"]:
        where = session.storage.root if session.storage else args.output
        print("done: %s -> %s" % (status["name"], where))
        print("downloaded %s in %s (avg %s)" % (
            human_bytes(status["downloaded"]),
            human_time(status["elapsed"]),
            human_rate(status["downloaded"] / max(status["elapsed"], 1e-9)),
        ))
        return 0

    print("stopped at %.1f%% (%s of %s) - run the same command again to resume" % (
        status["progress"] * 100, human_bytes(status["done"]), human_bytes(status["total"])))
    return 1


async def run_seed(args: argparse.Namespace) -> int:
    args.seed = True
    args.dry_run = False
    args.no_verify = False
    args.no_upload = False
    return await run_download(args)


def run_info(args: argparse.Namespace) -> int:
    source = load_source(args.source)
    if isinstance(source, Metainfo):
        print(describe(source))
        return 0
    print("magnet link")
    print("  info hash: %s" % source.info_hash.hex())
    print("  name:      %s" % (source.display_name or "(unknown until metadata is fetched)"))
    for url in source.trackers:
        print("  tracker:   %s" % url)
    return 0


def run_create(args: argparse.Namespace) -> int:
    def progress(done: int, total: int) -> None:
        if IS_TTY and total:
            sys.stdout.write("\r\033[2Khashing %5.1f%%" % (100.0 * done / total))
            sys.stdout.flush()

    raw = create_torrent(
        args.path,
        args.tracker or [],
        piece_length=args.piece_length,
        private=args.private,
        comment=args.comment or "",
        progress=progress,
    )
    if IS_TTY:
        sys.stdout.write("\r\033[2K")

    output = args.output or (os.path.basename(os.path.abspath(args.path.rstrip(os.sep))) + ".torrent")
    with open(output, "wb") as handle:
        handle.write(raw)
    meta = Metainfo.from_bytes(raw)
    print("wrote %s" % output)
    print(describe(meta))
    return 0


# -- argument parsing ---------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="torrentdl",
        description="A BitTorrent client in pure Python. Downloads .torrent files and magnet links.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""examples:
  torrentdl ubuntu.torrent -o ~/Downloads
  torrentdl "magnet:?xt=urn:btih:..." -o ~/Downloads --seed
  torrentdl info ubuntu.torrent
  torrentdl create ~/Movies/clip.mp4 --tracker udp://tracker.opentrackr.org:1337/announce
""",
    )
    parser.add_argument("--version", action="version", version="pytorrent %s" % __version__)
    sub = parser.add_subparsers(dest="command")

    def add_download_arguments(target: argparse.ArgumentParser) -> None:
        target.add_argument("source", help=".torrent path, magnet: URI, or http(s) URL to a .torrent")
        target.add_argument("-o", "--output", default=os.getcwd(), help="download directory (default: cwd)")
        target.add_argument("-p", "--port", type=int, default=6881, help="listening port (default: 6881)")
        target.add_argument("--max-peers", type=int, default=60, help="peer connection limit (default: 60)")
        target.add_argument("--tracker", action="append", help="extra tracker URL (repeatable)")
        target.add_argument("--peer", action="append", help="connect directly to host:port (repeatable)")
        target.add_argument("--seed", action="store_true", help="keep seeding after the download finishes")
        target.add_argument("--no-upload", action="store_true", help="do not serve data to other peers")
        target.add_argument("--no-verify", action="store_true", help="skip hash-checking existing files")
        target.add_argument("-q", "--quiet", action="store_true", help="no progress display")
        target.add_argument("--dry-run", action="store_true", help="show what would be downloaded and exit")

    download = sub.add_parser("download", help="download a torrent (default)")
    add_download_arguments(download)

    seed = sub.add_parser("seed", help="seed a torrent whose files you already have")
    add_download_arguments(seed)

    info = sub.add_parser("info", help="print a torrent's contents")
    info.add_argument("source", help=".torrent path, magnet: URI, or http(s) URL")

    daemon = sub.add_parser("daemon", help="run the JSON engine used by the Swarm app")
    daemon.add_argument("--support-dir", help="where to keep state (default: Application Support)")

    create = sub.add_parser("create", help="create a .torrent from a file or directory")
    create.add_argument("path", help="file or directory to share")
    create.add_argument("-o", "--output", help="output .torrent path")
    create.add_argument("--tracker", action="append", help="tracker URL (repeatable)")
    create.add_argument("--piece-length", type=int, help="piece size in bytes (default: automatic)")
    create.add_argument("--private", action="store_true", help="mark as private (no DHT/PEX)")
    create.add_argument("--comment", help="free-text comment")

    return parser


COMMANDS = ("download", "seed", "info", "create", "daemon")


def normalise_argv(argv: List[str]) -> List[str]:
    """Let `torrentdl <source> [flags]` and `torrentdl [flags] <source>` both work."""
    if not argv or argv[0] in COMMANDS:
        return argv
    if argv[0] in ("-h", "--help", "--version"):
        return argv
    return ["download"] + argv


def main(argv: Optional[List[str]] = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    parser = build_parser()

    args = parser.parse_args(normalise_argv(argv))
    command = args.command or "download"

    try:
        if command == "info":
            return run_info(args)
        if command == "create":
            return run_create(args)
        if command == "daemon":
            from .daemon import main as daemon_main

            return daemon_main(args.support_dir)

        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        try:
            if command == "seed":
                return loop.run_until_complete(run_seed(args))
            return loop.run_until_complete(run_download(args))
        finally:
            try:
                loop.run_until_complete(asyncio.sleep(0.05))
            except Exception:
                pass
            loop.close()
    except KeyboardInterrupt:
        print("\ninterrupted", file=sys.stderr)
        return 130
    except (MetainfoError, FileNotFoundError, ValueError, OSError) as exc:
        print("error: %s" % exc, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
