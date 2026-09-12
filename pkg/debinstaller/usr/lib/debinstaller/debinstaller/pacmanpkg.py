"""Build native pacman packages from extracted Debian package trees."""

from __future__ import annotations

import os
import re
import shutil
import stat
import subprocess
import tarfile
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path

from .archive import add_bytes, compress_xz, compress_zstd
from .debfile import DebPackage

DEB2ARCH = {
    "all": "any",
    "any": "any",
    "amd64": "x86_64",
    "arm64": "aarch64",
    "armhf": "armv7h",
    "armel": "armv7h",
    "i386": "i686",
    "mips64el": "mips64el",
    "loong64": "loong64",
    "ppc64el": "powerpc64le",
    "riscv64": "riscv64",
    "s390x": "s390x",
}

_INVALID_NAME = re.compile(r"[^a-z0-9@._+-]")
_INVALID_VER = re.compile(r"[^A-Za-z0-9._+]")
_LICENSE_PATTERNS = [
    (r"\bMIT\b", "MIT"),
    (r"\bApache[- ]2(\.0)?\b", "Apache-2.0"),
    (r"\bGPL[- ]?3", "GPL-3.0-or-later"),
    (r"\bGPL[- ]?2", "GPL-2.0-or-later"),
    (r"\bLGPL[- ]?3", "LGPL-3.0-or-later"),
    (r"\bLGPL[- ]?2", "LGPL-2.1-or-later"),
    (r"\bMPL[- ]?2", "MPL-2.0"),
    (r"\bBSD[- ]?3", "BSD-3-Clause"),
    (r"\bBSD[- ]?2", "BSD-2-Clause"),
    (r"\bISC\b", "ISC"),
    (r"\bUnlicense\b", "Unlicense"),
]


@dataclass
class PackageInfo:
    pkgname: str
    pkgver: str
    pkgrel: str
    pkgdesc: str
    url: str
    license: str
    arch: str
    deps: list[str] = field(default_factory=list)
    deb_version: str = ""
    deb_arch: str = ""
    renamed: bool = False

    @property
    def filename(self) -> str:
        return f"{self.pkgname}-{self.pkgver}-{self.pkgrel}-{self.arch}.pkg.tar.zst"


def map_deb_arch(deb_arch: str) -> str:
    return DEB2ARCH.get(deb_arch.lower(), deb_arch.lower() or "any")


def current_arch() -> str:
    import platform

    machine = platform.machine().lower()
    return {"amd64": "x86_64", "arm64": "aarch64"}.get(machine, machine)


def sanitize_pkgname(name: str) -> str:
    name = name.strip().lower().replace("_", "-")
    name = _INVALID_NAME.sub("-", name)
    name = re.sub(r"-{2,}", "-", name).strip("-")
    return name or "deb-package"


def deb_version_to_pacman(version: str) -> tuple[str, str]:
    """Convert a Debian version to (pkgver, pkgrel)."""
    version = version.strip() or "0"
    if ":" in version:  # epoch: drop it, pacman has no epoch concept
        version = version.split(":", 1)[1]
    if "-" in version:
        upstream, revision = version.rsplit("-", 1)
    else:
        upstream, revision = version, ""

    if revision and re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", revision):
        pkgrel = revision
        pkgver = upstream
    elif revision:
        pkgver = f"{upstream}.{revision}"
        pkgrel = "1"
    else:
        pkgver = upstream
        pkgrel = "1"

    pkgver = _INVALID_VER.sub(".", pkgver).strip(".") or "0"
    pkgrel = _INVALID_VER.sub(".", pkgrel).strip(".") or "1"
    return pkgver, pkgrel


def detect_license(root: Path, deb_name: str) -> str:
    candidates = [
        root / "usr/share/doc" / deb_name / "copyright",
        root / "usr/share/doc" / deb_name.lower() / "copyright",
    ]
    for candidate in candidates:
        if not candidate.is_file():
            continue
        try:
            text = candidate.read_text("utf-8", "replace")[:16384]
        except OSError:
            continue
        found = [spdx for pattern, spdx in _LICENSE_PATTERNS if re.search(pattern, text, re.I)]
        if found:
            return " AND ".join(dict.fromkeys(found[:2]))
    return "custom"


def package_info(
    deb: DebPackage,
    *,
    name: str | None = None,
    deps: list[str] | None = None,
    license_override: str | None = None,
) -> PackageInfo:
    original = sanitize_pkgname(deb.name)
    pkgname = sanitize_pkgname(name) if name else original
    pkgver, pkgrel = deb_version_to_pacman(deb.version)
    return PackageInfo(
        pkgname=pkgname,
        pkgver=pkgver,
        pkgrel=pkgrel,
        pkgdesc=deb.synopsis or f"Converted Debian package {deb.name}",
        url=deb.field("Homepage"),
        license=license_override or "custom",
        arch=map_deb_arch(deb.arch),
        deps=list(deps or []),
        deb_version=deb.version,
        deb_arch=deb.arch,
        renamed=pkgname != original,
    )


def collect_files(root: Path) -> list[tuple[str, os.stat_result]]:
    """Return (relpath, lstat) for everything under *root*, sorted."""
    result: list[tuple[str, os.stat_result]] = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        rel_dir = os.path.relpath(dirpath, root)
        if rel_dir == ".":
            for name in sorted(dirnames):
                full = Path(dirpath) / name
                result.append((name, os.lstat(full)))
        for name in sorted(dirnames):
            if rel_dir == ".":
                continue
            full = Path(dirpath) / name
            result.append((os.path.join(rel_dir, name), os.lstat(full)))
        for name in sorted(filenames):
            full = Path(dirpath) / name
            rel = name if rel_dir == "." else os.path.join(rel_dir, name)
            result.append((rel, os.lstat(full)))
    result.sort(key=lambda item: item[0])
    return result


def _installed_size(files: list[tuple[str, os.stat_result]]) -> int:
    total = 0
    for _, st in files:
        if stat.S_ISREG(st.st_mode):
            total += st.st_size
    return total


def _backup_entries(
    files: list[tuple[str, os.stat_result]], conffiles: list[str]
) -> list[str]:
    backups = {
        conffile.lstrip("/")
        for conffile in conffiles
        if conffile.lstrip("/")
    }
    for relpath, st in files:
        if stat.S_ISREG(st.st_mode) and relpath.startswith("etc/"):
            backups.add(relpath)
    return sorted(backups)


def render_pkginfo(
    info: PackageInfo,
    files: list[tuple[str, os.stat_result]],
    backups: list[str],
    *,
    generator: str,
) -> str:
    lines = [
        "# Generated by debinstaller",
        f"pkgname = {info.pkgname}",
        f"pkgbase = {info.pkgname}",
        f"pkgver = {info.pkgver}-{info.pkgrel}",
    ]
    if info.pkgdesc:
        lines.append(f"pkgdesc = {info.pkgdesc}")
    if info.url:
        lines.append(f"url = {info.url}")
    lines += [
        f"builddate = {int(time.time())}",
        f"packager = {generator}",
        f"size = {_installed_size(files)}",
        f"arch = {info.arch}",
        f"license = {info.license}",
    ]
    if info.deb_version:
        lines.append(f"xdata = debversion={info.deb_version}")
    for dep in sorted(set(info.deps)):
        lines.append(f"depend = {dep}")
    for backup in backups:
        lines.append(f"backup = {backup}")
    return "\n".join(lines) + "\n"


def build_pacman_package(
    root: Path,
    info: PackageInfo,
    output_dir: Path,
    *,
    conffiles: list[str] | None = None,
    generator: str = "debinstaller",
) -> Path:
    """Tar up an extracted tree as a pacman-installable package."""
    output_dir.mkdir(parents=True, exist_ok=True)
    files = collect_files(root)
    backups = _backup_entries(files, conffiles or [])
    pkginfo = render_pkginfo(info, files, backups, generator=generator)

    tmp_tar = Path(tempfile.mkstemp(suffix=".pkg.tar", dir=output_dir)[1])
    final = output_dir / info.filename
    try:
        with tarfile.open(tmp_tar, "w", format=tarfile.GNU_FORMAT) as tar:
            add_bytes(tar, ".PKGINFO", pkginfo.encode("utf-8"))
            for relpath, st in files:
                full = root / relpath
                tarinfo = tar.gettarinfo(str(full), arcname=relpath)
                tarinfo.uid = tarinfo.gid = 0
                tarinfo.uname = tarinfo.gname = "root"
                if stat.S_ISREG(st.st_mode):
                    with open(full, "rb") as handle:
                        tar.addfile(tarinfo, handle)
                else:
                    tar.addfile(tarinfo)
        if shutil.which("zstd"):
            compress_zstd(tmp_tar, final)
        else:
            final = output_dir / info.filename.replace(".tar.zst", ".tar.xz")
            compress_xz(tmp_tar, final)
        os.chmod(final, 0o644)
    finally:
        try:
            os.chmod(tmp_tar, 0o600)
            tmp_tar.unlink()
        except OSError:
            pass
    return final


def pacman_binary() -> str | None:
    return shutil.which("pacman")


def _pacman_query(args: tuple[str, ...], name: str) -> bool:
    pacman = pacman_binary()
    if not pacman:
        return False
    env = dict(os.environ, LC_ALL="C")
    result = subprocess.run([pacman, *args, name], capture_output=True, text=True, env=env)
    return result.returncode == 0


def pacman_is_installed(name: str) -> bool:
    """True if a package with this name is currently installed."""
    return _pacman_query(("-Q",), name)


def pacman_in_repos(name: str) -> bool:
    """True if a package with this name exists in the sync databases."""
    return _pacman_query(("-Si",), name)


def pacman_has_package(name: str) -> bool:
    """True if *name* is installed locally or exists in the sync databases."""
    return pacman_is_installed(name) or pacman_in_repos(name)
