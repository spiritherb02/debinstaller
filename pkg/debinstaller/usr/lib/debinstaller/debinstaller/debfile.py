"""Parsing and extraction of Debian binary packages (.deb)."""

from __future__ import annotations

import os
import re
import tarfile
from dataclasses import dataclass
from pathlib import Path

from .archive import open_tar_bytes
from .arfile import ArError, ArEntry, read_ar

MAINTAINER_SCRIPTS = ("preinst", "postinst", "prerm", "postrm", "config")


class DebError(Exception):
    """Raised for malformed or unsupported .deb packages."""


@dataclass(frozen=True)
class DepAlternative:
    """One alternative of a Debian dependency, e.g. ``libssl3 (>= 3.0)``."""

    name: str
    constraint: str = ""

    def __str__(self) -> str:
        return f"{self.name} ({self.constraint})" if self.constraint else self.name


@dataclass
class ExtractedFile:
    relpath: str
    size: int
    mode: int
    kind: str  # file | dir | symlink | other
    linkname: str = ""


_DEP_SPLIT = re.compile(r"\s*,\s*")
_ALT_SPLIT = re.compile(r"\s*\|\s*")
_ARCH_QUAL = re.compile(r"\[([^\]]*)\]")
_PROFILE_QUAL = re.compile(r"<[^>]*>")


def _parse_dep_alternative(text: str) -> DepAlternative | None:
    text = _PROFILE_QUAL.sub("", text).strip()
    arch_qual = _ARCH_QUAL.search(text)
    text = _ARCH_QUAL.sub("", text).strip()
    m = re.match(r"^([A-Za-z0-9][A-Za-z0-9+._:-]*)\s*(?:\((.*?)\))?\s*$", text)
    if not m:
        return None
    name, constraint = m.group(1), (m.group(2) or "").strip()
    alt = DepAlternative(name=name, constraint=constraint)
    if arch_qual:
        # Keep the qualifier in the constraint so the caller can filter it.
        alt = DepAlternative(name=name, constraint=f"{constraint} [{arch_qual.group(1)}]")
    return alt


def split_arch_qualifier(alt: DepAlternative, deb_arch: str) -> bool:
    """Return False if the alternative does not apply to *deb_arch*."""
    m = _ARCH_QUAL.search(alt.constraint)
    if not m:
        return True
    arches = [a.strip() for a in m.group(1).split() if a.strip()]
    negated = [a.startswith("!") for a in arches]
    arches = [a.lstrip("!") for a in arches]
    if any(negated) and deb_arch in arches:
        return False
    if not any(negated) and deb_arch not in arches:
        return False
    return True


class DebPackage:
    """Read-only view of a .deb file."""

    def __init__(self, path: str | os.PathLike[str]) -> None:
        self.path = Path(path)
        if not self.path.is_file():
            raise DebError(f"{self.path}: no such file")
        self.control: dict[str, str] = {}
        self.members: dict[str, bytes] = {}
        self.data_name: str = ""
        self.data_bytes: bytes = b""
        self._parse()

    # ------------------------------------------------------------------ parse

    def _parse(self) -> None:
        try:
            entries: list[ArEntry] = read_ar(self.path)
        except ArError as exc:
            raise DebError(str(exc)) from exc

        if not entries:
            raise DebError(f"{self.path}: empty archive")

        by_name = {e.name: e for e in entries}
        deb_binary = by_name.get("debian-binary")
        if deb_binary is None:
            raise DebError(f"{self.path}: missing debian-binary (not a .deb?)")
        version = deb_binary.data.strip().decode("ascii", "replace")
        if not version.startswith("2."):
            raise DebError(f"{self.path}: unsupported .deb format version {version!r}")

        control_entry = next((e for e in entries if e.name.startswith("control.tar")), None)
        data_entry = next((e for e in entries if e.name.startswith("data.tar")), None)
        if control_entry is None:
            raise DebError(f"{self.path}: missing control.tar member")
        if data_entry is None:
            raise DebError(f"{self.path}: missing data.tar member")

        self.control = self._read_control(control_entry)
        self.data_name = data_entry.name
        self.data_bytes = data_entry.data

    def _read_control(self, entry: ArEntry) -> dict[str, str]:
        fields: dict[str, str] = {}
        try:
            with open_tar_bytes(entry.data, entry.name) as tf:
                for member in tf.getmembers():
                    if not member.isfile() or member.size > 8 * 1024 * 1024:
                        continue
                    rel = member.name.lstrip("./").replace("\\", "/")
                    if not rel:
                        continue
                    handle = tf.extractfile(member)
                    self.members[rel] = handle.read() if handle else b""
        except (tarfile.TarError, RuntimeError) as exc:
            raise DebError(f"{self.path}: cannot read {entry.name}: {exc}") from exc

        raw = self.members.get("control")
        if raw is None:
            raise DebError(f"{self.path}: control file not found in {entry.name}")
        fields = parse_control(raw.decode("utf-8", "replace"))
        return fields

    # ---------------------------------------------------------------- getters

    def field(self, name: str, default: str = "") -> str:
        for key, value in self.control.items():
            if key.lower() == name.lower():
                return value
        return default

    @property
    def name(self) -> str:
        return self.field("Package") or self.path.stem.split("_")[0]

    @property
    def version(self) -> str:
        return self.field("Version")

    @property
    def arch(self) -> str:
        return self.field("Architecture", "all")

    @property
    def synopsis(self) -> str:
        desc = self.field("Description")
        for line in desc.splitlines():
            if line.strip():
                return line.strip()
        return ""

    @property
    def description(self) -> str:
        return self.field("Description")

    @property
    def installed_size(self) -> int:
        raw = self.field("Installed-Size").strip()
        try:
            return int(raw) * 1024  # the field is in KiB
        except ValueError:
            return 0

    @property
    def conffiles(self) -> list[str]:
        raw = self.members.get("conffiles")
        if not raw:
            return []
        result = []
        for line in raw.decode("utf-8", "replace").splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                result.append(line.split()[0])
        return result

    @property
    def maintainer_scripts(self) -> list[str]:
        return [s for s in MAINTAINER_SCRIPTS if s in self.members]

    def dependency_groups(self) -> list[list[DepAlternative]]:
        """Parse Depends/Pre-Depends into groups of alternatives."""
        groups: list[list[DepAlternative]] = []
        for fieldname in ("Pre-Depends", "Depends"):
            for group in _DEP_SPLIT.split(self.field(fieldname).strip()):
                if not group:
                    continue
                alternatives: list[DepAlternative] = []
                for part in _ALT_SPLIT.split(group):
                    alt = _parse_dep_alternative(part.strip())
                    if alt is None or not split_arch_qualifier(alt, self.arch):
                        continue
                    alternatives.append(alt)
                if alternatives:
                    groups.append(alternatives)
        return groups

    def recommend_groups(self) -> list[list[DepAlternative]]:
        groups: list[list[DepAlternative]] = []
        for group in _DEP_SPLIT.split(self.field("Recommends").strip()):
            if not group:
                continue
            alternatives = [_parse_dep_alternative(p.strip()) for p in _ALT_SPLIT.split(group)]
            alt_list = [a for a in alternatives if a is not None]
            if alt_list:
                groups.append(alt_list)
        return groups

    # -------------------------------------------------------------- extraction

    def data_members(self) -> list[tarfile.TarInfo]:
        """List the data.tar members without extracting anything."""
        try:
            with open_tar_bytes(self.data_bytes, self.data_name) as tf:
                return tf.getmembers()
        except (tarfile.TarError, RuntimeError) as exc:
            raise DebError(f"{self.path}: cannot read {self.data_name}: {exc}") from exc

    def extract_data(self, dest: str | os.PathLike[str]) -> list[ExtractedFile]:
        """Extract data.tar into *dest*, refusing path-traversal entries."""
        destination = Path(dest)
        destination.mkdir(parents=True, exist_ok=True)
        extracted: list[ExtractedFile] = []
        try:
            with open_tar_bytes(self.data_bytes, self.data_name) as tf:
                for member in tf.getmembers():
                    rel = _safe_relpath(member.name)
                    if rel is None:
                        raise DebError(
                            f"{self.path}: refusing unsafe path in archive: {member.name!r}"
                        )
                    if member.isdir():
                        kind = "dir"
                    elif member.issym():
                        kind = "symlink"
                    elif member.isfile():
                        kind = "file"
                    else:
                        kind = "other"
                    extracted.append(
                        ExtractedFile(
                            relpath=rel,
                            size=member.size,
                            mode=member.mode,
                            kind=kind,
                            linkname=member.linkname,
                        )
                    )
                _extract_all(tf, destination)
        except (tarfile.TarError, RuntimeError) as exc:
            raise DebError(f"{self.path}: cannot extract {self.data_name}: {exc}") from exc
        return extracted

    def save_maintainer_scripts(self, dest: str | os.PathLike[str]) -> dict[str, Path]:
        """Write the maintainer scripts to *dest* and return name -> path."""
        target = Path(dest)
        target.mkdir(parents=True, exist_ok=True)
        saved: dict[str, Path] = {}
        for script in self.maintainer_scripts:
            path = target / script
            path.write_bytes(self.members[script])
            path.chmod(0o755)
            saved[script] = path
        return saved

    # ------------------------------------------------------------------ misc

    def summary(self) -> dict[str, object]:
        return {
            "file": str(self.path),
            "package": self.name,
            "version": self.version,
            "architecture": self.arch,
            "maintainer": self.field("Maintainer"),
            "homepage": self.field("Homepage"),
            "depends": self.field("Depends"),
            "recommends": self.field("Recommends"),
            "description": self.synopsis,
            "installed_size": self.installed_size,
            "conffiles": self.conffiles,
            "scripts": self.maintainer_scripts,
        }


def parse_control(text: str) -> dict[str, str]:
    """Parse an RFC-822-ish Debian control file (continuation lines included)."""
    fields: dict[str, str] = {}
    current: str | None = None
    for line in text.replace("\r\n", "\n").split("\n"):
        if not line.strip():
            current = None
            continue
        if line[0] in " \t" and current is not None:
            fields[current] += "\n" + line[1:]
            continue
        if ":" in line:
            key, value = line.split(":", 1)
            current = key.strip()
            fields[current] = value.strip()
        else:
            current = None
    return fields


def _safe_relpath(name: str) -> str | None:
    name = name.replace("\\", "/")
    if name in ("", ".", "./"):
        return ""
    parts = []
    for part in name.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            return None
        parts.append(part)
    if not parts:
        return ""
    return "/".join(parts)


def _extract_all(tf: tarfile.TarFile, dest: Path) -> None:
    import sys

    kwargs: dict[str, object] = {"numeric_owner": False}
    if sys.version_info >= (3, 12):
        kwargs["filter"] = "fully_trusted"
    tf.extractall(dest, **kwargs)
