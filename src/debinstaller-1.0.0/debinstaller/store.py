"""JSON state database for packages installed by debinstaller."""

from __future__ import annotations

import json
import os
from dataclasses import asdict, dataclass, field
from pathlib import Path

DEFAULT_STATE_DIR = Path("/var/lib/debinstaller")


def state_dir() -> Path:
    override = os.environ.get("DEBINSTALLER_STATE_DIR")
    return Path(override) if override else DEFAULT_STATE_DIR


def scripts_root() -> Path:
    return state_dir() / "scripts"


def _state_file() -> Path:
    return state_dir() / "state.json"


@dataclass
class PackageRecord:
    pkgname: str
    deb_package: str
    deb_version: str
    deb_arch: str
    deb_file: str
    installed_at: str
    scripts: list[str] = field(default_factory=list)
    deps: list[str] = field(default_factory=list)
    files: list[str] = field(default_factory=list)
    pacman_package: str = ""
    renamed_from: str = ""

    def to_dict(self) -> dict:
        return asdict(self)

    @classmethod
    def from_dict(cls, data: dict) -> "PackageRecord":
        known = {f for f in cls.__dataclass_fields__}  # type: ignore[attr-defined]
        return cls(**{k: v for k, v in data.items() if k in known})


def load() -> dict[str, PackageRecord]:
    path = _state_file()
    if not path.is_file():
        return {}
    try:
        raw = json.loads(path.read_text("utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    records: dict[str, PackageRecord] = {}
    for name, data in raw.get("packages", {}).items():
        if isinstance(data, dict):
            records[name] = PackageRecord.from_dict(data)
    return records


def save(records: dict[str, PackageRecord]) -> None:
    directory = state_dir()
    directory.mkdir(parents=True, exist_ok=True)
    payload = {
        "version": 1,
        "packages": {name: rec.to_dict() for name, rec in records.items()},
    }
    tmp = _state_file().with_suffix(".json.tmp")
    tmp.write_text(json.dumps(payload, indent=2, ensure_ascii=False), "utf-8")
    tmp.replace(_state_file())


def record(package: PackageRecord) -> None:
    records = load()
    records[package.pkgname] = package
    save(records)


def lookup(name: str) -> PackageRecord | None:
    records = load()
    return records.get(name)


def forget(name: str) -> None:
    records = load()
    if name in records:
        del records[name]
        save(records)
