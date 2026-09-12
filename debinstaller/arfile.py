"""Minimal reader for ar(5) archives, the container format used by .deb files."""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

AR_MAGIC = b"!<arch>\n"


class ArError(Exception):
    """Raised when an ar archive cannot be parsed."""


@dataclass
class ArEntry:
    name: str
    data: bytes


def read_ar(path: str | os.PathLike[str]) -> list[ArEntry]:
    """Parse *path* and return all archive members.

    Supports both the GNU (``name/``) and BSD (``#1/len``) name variants.
    """
    entries: list[ArEntry] = []
    with open(path, "rb") as fh:
        if fh.read(len(AR_MAGIC)) != AR_MAGIC:
            raise ArError(f"{path}: not an ar archive (bad magic)")

        while True:
            header = fh.read(60)
            if not header:
                break
            if len(header) != 60 or header[58:60] != b"`\n":
                raise ArError(f"{path}: malformed ar header")

            raw_name = header[:16].decode("ascii", "replace").strip()
            try:
                size = int(header[48:58].decode("ascii").strip() or "0")
            except ValueError as exc:
                raise ArError(f"{path}: bad size field for entry {raw_name!r}") from exc

            data = fh.read(size)
            if len(data) != size:
                raise ArError(f"{path}: truncated archive entry {raw_name!r}")
            if size % 2:  # entries are padded to an even offset
                fh.read(1)

            name = raw_name
            if name.startswith("#1/"):  # BSD long name
                name_len = int(name[3:].strip() or "0")
                name = data[:name_len].decode("utf-8", "replace")
                data = data[name_len:]

            entries.append(ArEntry(name=name.rstrip("/"), data=data))

    return entries


def write_ar(path: str | os.PathLike[str], members: list[tuple[str, bytes]]) -> None:
    """Write a (GNU style) ar archive, used by the test-suite."""
    out = bytearray(AR_MAGIC)
    for name, data in members:
        header = (
            f"{name + '/':<16}"
            f"{0:<12}{0:<6}{0:<6}{'100644':<8}{len(data):<10}`\n"
        ).encode("ascii")
        out += header
        out += data
        if len(data) % 2:
            out += b"\n"
    Path(path).write_bytes(bytes(out))
