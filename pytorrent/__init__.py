"""pytorrent - a BitTorrent client in pure Python (standard library only)."""

__version__ = "1.0"

from .metainfo import Metainfo, MagnetLink, parse_magnet  # noqa: F401
from .session import Session  # noqa: F401
