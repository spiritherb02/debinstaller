"""Small helpers around tarfile, with a zstd fallback for Python < 3.14."""

from __future__ import annotations

import io
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path


def _tarfile_supports_zstd() -> bool:
    try:  # Python 3.14+
        import compression.zstd  # noqa: F401

        return True
    except ImportError:
        return False


def open_tar_bytes(data: bytes, name: str = "") -> tarfile.TarFile:
    """Open a tar stream held in memory (gzip/xz/bzip2/zstd).

    The caller is responsible for closing the returned TarFile.
    """
    try:
        return tarfile.open(fileobj=io.BytesIO(data), mode="r:*")
    except tarfile.TarError:
        if not (name.endswith(".zst") or name.endswith(".zstd")):
            raise
        if _tarfile_supports_zstd():
            raise
        # Old Python without native zstd support: decompress out-of-process.
        zstd = shutil.which("zstd")
        if not zstd:
            raise RuntimeError(
                f"cannot open {name}: this Python lacks zstd support and no "
                "`zstd` binary was found in PATH"
            )
        tmp = Path(tempfile.mkstemp(suffix=".tar")[1])
        try:
            with tmp.open("wb") as out:
                subprocess.run([zstd, "-dc", "-"], input=data, stdout=out, check=True)
            return tarfile.open(tmp, mode="r:")
        finally:
            tmp.unlink(missing_ok=True)


def add_bytes(tar: tarfile.TarFile, name: str, data: bytes, mode: int = 0o644) -> None:
    """Append an in-memory file to an uncompressed tar archive."""
    import time

    info = tarfile.TarInfo(name)
    info.size = len(data)
    info.mode = mode
    info.mtime = int(os.environ.get("SOURCE_DATE_EPOCH") or time.time())
    info.uid = info.gid = 0
    info.uname = info.gname = "root"
    tar.addfile(info, io.BytesIO(data))


def compress_zstd(src: Path, dest: Path, level: int = 10) -> None:
    """Compress *src* to *dest* with zstd (multi-threaded)."""
    zstd = shutil.which("zstd")
    if not zstd:
        raise RuntimeError("zstd binary not found")
    subprocess.run(
        [zstd, "-q", "-f", f"-{level}", "-T0", str(src), "-o", str(dest)],
        check=True,
    )


def compress_xz(src: Path, dest: Path) -> None:
    import lzma

    with open(src, "rb") as fi, lzma.open(dest, "wb", preset=6) as fo:
        shutil.copyfileobj(fi, fo)


def python_has_zstd() -> bool:
    return sys.version_info >= (3, 14) or _tarfile_supports_zstd()
