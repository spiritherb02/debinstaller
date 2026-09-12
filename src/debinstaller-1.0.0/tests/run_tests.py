#!/usr/bin/env python3
"""Self-contained test-suite:  python3 tests/run_tests.py"""

from __future__ import annotations

import io
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from debinstaller import pacmanpkg  # noqa: E402
from debinstaller.arfile import ArError, read_ar, write_ar  # noqa: E402
from debinstaller.cli import main  # noqa: E402
from debinstaller.debfile import DebError, DebPackage, parse_control  # noqa: E402
from debinstaller.depmap import map_name  # noqa: E402


def _tar_gz(entries: dict[str, object]) -> bytes:
    """entries: name -> (bytes, mode) | None for a directory | ('symlink', target)."""
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:gz") as tar:
        for name, value in entries.items():
            info = tarfile.TarInfo(name)
            if value is None:
                info.type = tarfile.DIRTYPE
                info.mode = 0o755
                tar.addfile(info)
            elif isinstance(value, tuple) and value and value[0] == "symlink":
                info.type = tarfile.SYMTYPE
                info.linkname = value[1]
                info.mode = 0o777
                tar.addfile(info)
            else:
                data, mode = value  # type: ignore[misc]
                info.size = len(data)
                info.mode = mode
                tar.addfile(info, io.BytesIO(data))
    return buffer.getvalue()


DEFAULT_DATA = {
    "./usr/": None,
    "./usr/bin/": None,
    "./usr/bin/demo": (b"#!/bin/sh\necho demo\n", 0o755),
    "./usr/bin/demo-link": ("symlink", "demo"),
    "./usr/lib/demo/": None,
    "./usr/lib/demo/libdemo.so.1": (b"\x7fELF fake", 0o644),
    "./usr/share/doc/demo-pkg/copyright": (b"MIT License\n\nPermission is hereby granted\n", 0o644),
    "./etc/demo/demo.conf": (b"enabled=true\n", 0o644),
    "./usr/share/applications/demo.desktop": (b"[Desktop Entry]\nName=Demo\n", 0o644),
}


def make_deb(
    path: Path,
    *,
    name: str = "demo-pkg",
    version: str = "1.2.3-1",
    arch: str = "amd64",
    depends: str = "libc6 (>= 2.34), zenity | kdialog, libnotreal1, debconf",
    scripts: tuple[str, ...] = ("postinst",),
    data: dict[str, object] | None = None,
) -> Path:
    control = (
        f"Package: {name}\n"
        f"Version: {version}\n"
        f"Architecture: {arch}\n"
        "Maintainer: Test <test@example.com>\n"
        f"Depends: {depends}\n"
        "Description: Demo package\n"
        " A longer description that spans lines.\n"
        "Homepage: https://example.com/demo\n"
        "Installed-Size: 42\n"
    ).encode()
    control_entries: dict[str, object] = {
        "./control": (control, 0o644),
        "./conffiles": (b"/etc/demo/demo.conf\n", 0o644),
    }
    for script in scripts:
        control_entries[f"./{script}"] = (b"#!/bin/sh\nexit 0\n", 0o755)

    write_ar(
        path,
        [
            ("debian-binary", b"2.0\n"),
            ("control.tar.gz", _tar_gz(control_entries)),
            ("data.tar.gz", _tar_gz(DEFAULT_DATA if data is None else data)),
        ],
    )
    return path


class ArTests(unittest.TestCase):
    def test_roundtrip(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "x.ar"
            write_ar(path, [("a", b"hello"), ("b", b"world!")])
            entries = read_ar(path)
            self.assertEqual([e.name for e in entries], ["a", "b"])
            self.assertEqual(entries[1].data, b"world!")

    def test_bad_magic(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "x.ar"
            path.write_bytes(b"not an archive")
            with self.assertRaises(ArError):
                read_ar(path)


class ControlTests(unittest.TestCase):
    def test_continuation_lines(self) -> None:
        fields = parse_control("Package: foo\nDescription: short\n long line\n\nVersion: 1\n")
        self.assertEqual(fields["Package"], "foo")
        self.assertEqual(fields["Description"], "short\nlong line")
        self.assertEqual(fields["Version"], "1")


class DebParseTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.deb_path = make_deb(Path(self.tmp.name) / "demo.deb")
        self.deb = DebPackage(self.deb_path)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_metadata(self) -> None:
        self.assertEqual(self.deb.name, "demo-pkg")
        self.assertEqual(self.deb.version, "1.2.3-1")
        self.assertEqual(self.deb.arch, "amd64")
        self.assertEqual(self.deb.synopsis, "Demo package")
        self.assertEqual(self.deb.installed_size, 42 * 1024)
        self.assertEqual(self.deb.conffiles, ["/etc/demo/demo.conf"])
        self.assertEqual(self.deb.maintainer_scripts, ["postinst"])

    def test_dependency_groups(self) -> None:
        groups = self.deb.dependency_groups()
        names = [[a.name for a in group] for group in groups]
        self.assertIn(["zenity", "kdialog"], names)
        self.assertIn(["libc6"], names)

    def test_extract(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            items = self.deb.extract_data(tmp)
            root = Path(tmp)
            self.assertTrue((root / "usr/bin/demo").is_file())
            self.assertTrue((root / "usr/bin/demo-link").is_symlink())
            self.assertEqual((root / "etc/demo/demo.conf").read_text(), "enabled=true\n")
            self.assertEqual(
                (root / "usr/bin/demo").stat().st_mode & 0o111, 0o111
            )
            kinds = {item.relpath: item.kind for item in items}
            self.assertEqual(kinds["usr/bin/demo-link"], "symlink")

    def test_rejects_traversal(self) -> None:
        evil = dict(DEFAULT_DATA)
        evil["../evil.txt"] = (b"pwned", 0o644)
        path = make_deb(Path(self.tmp.name) / "evil.deb", data=evil)
        with self.assertRaises(DebError):
            DebPackage(path).extract_data(Path(self.tmp.name) / "out")


class VersionTests(unittest.TestCase):
    def test_versions(self) -> None:
        cases = {
            "3.5.0": ("3.5.0", "1"),
            "1.0-2": ("1.0", "2"),
            "1:2.3-4ubuntu5": ("2.3.4ubuntu5", "1"),
            "2.0~beta1": ("2.0.beta1", "1"),
            "": ("0", "1"),
        }
        for raw, expected in cases.items():
            self.assertEqual(pacmanpkg.deb_version_to_pacman(raw), expected)

    def test_names(self) -> None:
        self.assertEqual(pacmanpkg.sanitize_pkgname("Some_Package"), "some-package")
        self.assertEqual(pacmanpkg.map_deb_arch("amd64"), "x86_64")
        self.assertEqual(pacmanpkg.map_deb_arch("all"), "any")


class DepMapTests(unittest.TestCase):
    def test_mapping(self) -> None:
        self.assertEqual(map_name("libc6"), ("glibc", "mapped"))
        self.assertEqual(map_name("libgtk-3-0"), ("gtk3", "mapped"))
        self.assertEqual(map_name("python3-requests"), ("python-requests", "mapped"))
        self.assertEqual(map_name("python3-foobar"), ("python-foobar", "heuristic"))
        self.assertEqual(map_name("libcurl4-openssl-dev"), ("curl", "mapped"))
        self.assertEqual(map_name("libfoo-dev"), ("libfoo", "heuristic"))
        self.assertEqual(map_name("libnotreal9-dev"), ("libnotreal", "heuristic"))
        self.assertEqual(map_name("debconf"), (None, "skipped"))
        self.assertEqual(map_name("libweird1"), (None, "unknown"))
        self.assertEqual(map_name("zenity"), ("zenity", "mapped"))
        self.assertEqual(map_name("htop"), ("htop", "same"))


class ConvertTests(unittest.TestCase):
    def test_build_package(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            deb = DebPackage(make_deb(tmp_path / "demo.deb"))
            root = tmp_path / "root"
            deb.extract_data(root)
            info = pacmanpkg.package_info(
                deb,
                name="demo-pkg",
                deps=["glibc"],
                license_override=pacmanpkg.detect_license(root, deb.name),
            )
            package = pacmanpkg.build_pacman_package(
                root, info, tmp_path / "out", conffiles=deb.conffiles
            )
            self.assertTrue(package.name.endswith(".pkg.tar.zst"))

            with tarfile.open(package, "r:*") as tar:
                names = tar.getnames()
                self.assertIn(".PKGINFO", names)
                self.assertIn("usr/bin/demo", names)
                self.assertEqual(names[0], ".PKGINFO")
                pkginfo = tar.extractfile(".PKGINFO").read().decode()
            self.assertIn("pkgname = demo-pkg", pkginfo)
            self.assertIn("pkgver = 1.2.3-1", pkginfo)
            self.assertIn("arch = x86_64", pkginfo)
            self.assertIn("depend = glibc", pkginfo)
            self.assertIn("backup = etc/demo/demo.conf", pkginfo)
            self.assertIn("license = MIT", pkginfo)

    def test_convert_cli(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            deb = make_deb(tmp_path / "demo.deb")
            out = tmp_path / "out"
            rc = main(["convert", "--no-deps", "-o", str(out), str(deb)])
            self.assertEqual(rc, 0)
            produced = list(out.glob("*.pkg.tar.zst"))
            self.assertEqual(len(produced), 1)


class CliTests(unittest.TestCase):
    def test_info(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            deb = make_deb(Path(tmp) / "demo.deb")
            self.assertEqual(main(["info", str(deb)]), 0)

    def test_extract_cli(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            deb = make_deb(Path(tmp) / "demo.deb")
            dest = Path(tmp) / "payload"
            self.assertEqual(main(["extract", str(deb), str(dest)]), 0)
            self.assertTrue((dest / "usr/bin/demo").is_file())


if __name__ == "__main__":
    unittest.main(verbosity=2)
