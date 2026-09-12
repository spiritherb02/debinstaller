"""Command line interface for debinstaller."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from . import __version__, pacmanpkg, store
from .archive import python_has_zstd
from .debfile import DebError, DebPackage
from .depmap import DepResolution, resolve

GENERATOR = f"debinstaller {__version__}"


# --------------------------------------------------------------------- output

def _supports_color() -> bool:
    return sys.stdout.isatty() and os.environ.get("NO_COLOR") is None


def _c(text: str, code: str) -> str:
    return f"\033[{code}m{text}\033[0m" if _supports_color() else text


def info(message: str) -> None:
    print(f"{_c('==>', '1;34')} {message}")


def ok(message: str) -> None:
    print(f"{_c('==>', '1;32')} {message}")


def note(message: str) -> None:
    print(f"{_c(' -->', '1;36')} {message}")


def warn(message: str) -> None:
    print(f"{_c('warning:', '1;33')} {message}", file=sys.stderr)


def error(message: str) -> None:
    print(f"{_c('error:', '1;31')} {message}", file=sys.stderr)


def human_size(num: float) -> str:
    for unit in ("B", "KiB", "MiB", "GiB"):
        if abs(num) < 1024 or unit == "GiB":
            return f"{num:.0f} {unit}" if unit == "B" else f"{num:.1f} {unit}"
        num /= 1024
    return f"{num:.1f} GiB"


# ------------------------------------------------------------------- plumbing

def root_prefix() -> list[str] | None:
    """Command prefix needed to run pacman (empty for root, sudo otherwise)."""
    if os.geteuid() == 0:
        return []
    sudo = shutil.which("sudo")
    return [sudo] if sudo else None


def run_as_root(cmd: list[str], *, check: bool = False) -> int:
    prefix = root_prefix()
    if prefix is None:
        error("root privileges are required (install sudo or run as root)")
        return 1
    full = prefix + cmd
    info("running: " + " ".join(full))
    return subprocess.run(full, check=check).returncode


def ask(question: str, assume_yes: bool) -> bool:
    if assume_yes:
        return True
    if not sys.stdin.isatty():
        return True
    try:
        answer = input(f"{question} [Y/n] ").strip().lower()
    except EOFError:
        return True
    return answer in ("", "y", "yes")


def load_deb(path: str | Path) -> DebPackage | None:
    try:
        return DebPackage(path)
    except DebError as exc:
        error(str(exc))
        return None


def default_output_dir(installing: bool) -> Path:
    if installing and os.geteuid() == 0:
        return Path("/var/cache/debinstaller")
    return Path.cwd()


# ------------------------------------------------------------- dependency work

def print_dependency_report(resolution: DepResolution, verbose: bool = False) -> None:
    info(
        f"dependencies: {len(resolution.groups)} groups — "
        f"{len(resolution.satisfied)} satisfied, {len(resolution.missing)} missing, "
        f"{len(resolution.unknown)} unknown, {len(resolution.skipped)} debian-only"
    )
    if resolution.satisfied:
        note("satisfied: " + ", ".join(resolution.satisfied))
    if resolution.missing:
        warn("missing:   " + ", ".join(resolution.missing))
    if resolution.unknown:
        warn("unknown:   " + ", ".join(resolution.unknown))
    if verbose:
        print(resolution.render())


def install_missing_deps(names: list[str], assume_yes: bool) -> bool:
    if not names:
        return True
    if not pacmanpkg.pacman_binary():
        warn("pacman not found; cannot install dependencies automatically")
        return False
    if not ask(f"Install {len(names)} Arch dependencies with pacman?", assume_yes):
        return False
    return run_as_root(["pacman", "-S", "--needed", "--noconfirm", *names]) == 0


def decide_dependencies(
    deb: DebPackage,
    resolution: DepResolution,
    *,
    no_deps: bool,
    install_deps: bool,
    strict: bool,
    all_deps: bool,
    assume_yes: bool,
) -> list[str] | None:
    if no_deps:
        note("dependency analysis skipped (--no-deps)")
        return []

    if not pacmanpkg.pacman_binary():
        deps = sorted(
            {
                candidate.arch_name
                for group in resolution.groups
                for candidate in group.candidates
                if candidate.arch_name and candidate.confidence in ("mapped", "heuristic", "same")
            }
        )
        if deps:
            note("pacman not found; all mapped dependencies are recorded verbatim")
        return deps

    if all_deps:
        return resolution.installable

    if resolution.missing and install_deps:
        if not install_missing_deps(resolution.missing, assume_yes):
            if strict:
                error("could not install missing dependencies (--strict-deps)")
                return None
            warn("continuing without the missing dependencies")

    problems = resolution.missing or resolution.unknown
    if strict and problems:
        error("unresolved dependencies (--strict-deps); aborting")
        return None
    if resolution.missing and not install_deps:
        warn(
            "missing dependencies are not recorded in the package; install them "
            "with: pacman -S " + " ".join(resolution.missing)
        )
    return resolution.satisfied


# ------------------------------------------------------------------ naming

def decide_pkgname(deb: DebPackage, override: str | None) -> str:
    base = pacmanpkg.sanitize_pkgname(deb.name)
    if override:
        return pacmanpkg.sanitize_pkgname(override)
    if store.lookup(base):
        return base
    if pacmanpkg.pacman_is_installed(base):
        warn(
            f"'{base}' is already installed; this conversion will be installed "
            "under the same name and replace it"
        )
        return base
    if pacmanpkg.pacman_in_repos(base):
        renamed = f"deb-{base}"
        warn(
            f"a package named '{base}' exists in the Arch repositories; "
            f"converting as '{renamed}'"
        )
        return renamed
    return base


# -------------------------------------------------------------- maintainer scripts

def run_maintainer_script(path: Path, action: str, deb_name: str) -> int:
    env = dict(
        os.environ,
        DEBIAN_FRONTEND="noninteractive",
        DPkg_MAINTSCRIPT_PACKAGE=deb_name,
        DEBIAN_MAINTSCRIPT_PACKAGE=deb_name,
        PATH=os.environ.get("PATH", "/usr/local/sbin:/usr/local/bin:/usr/bin"),
    )
    info(f"running maintainer script {path.name} ({action})")
    argv = [str(path), action]
    try:
        return subprocess.run(argv, env=env, cwd=str(path.parent)).returncode
    except OSError:
        # Scripts without a shebang: fall back to sh.
        return subprocess.run(["/bin/sh", *argv], env=env, cwd=str(path.parent)).returncode


# ------------------------------------------------------------------- fallback

def fallback_install(root: Path) -> list[str] | None:
    """Copy the extracted tree onto / when pacman is unavailable."""
    files = [rel for rel, _ in pacmanpkg.collect_files(root)]
    try:
        for relpath, st in pacmanpkg.collect_files(root):
            target = Path("/") / relpath
            source = root / relpath
            if stat.S_ISDIR(st.st_mode):
                target.mkdir(parents=True, exist_ok=True)
            elif stat.S_ISLNK(st.st_mode):
                target.parent.mkdir(parents=True, exist_ok=True)
                if target.is_symlink() or target.exists():
                    target.unlink()
                os.symlink(os.readlink(source), target)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target, follow_symlinks=False)
    except OSError as exc:
        error(f"fallback install failed: {exc}")
        return None
    return files


def fallback_remove(files: list[str]) -> None:
    for relpath in sorted(files, key=len, reverse=True):
        target = Path("/") / relpath
        try:
            if target.is_symlink() or target.is_file():
                target.unlink()
            elif target.is_dir():
                target.rmdir()
        except OSError:
            pass


# ------------------------------------------------------------------- commands

def cmd_info(args: argparse.Namespace) -> int:
    deb = load_deb(args.deb)
    if deb is None:
        return 1
    members = deb.data_members()
    total = sum(m.size for m in members if m.isfile())
    mapped_arch = pacmanpkg.map_deb_arch(deb.arch)
    pkgname = pacmanpkg.sanitize_pkgname(deb.name)
    if pacmanpkg.pacman_is_installed(pkgname):
        pkgname += " (already installed)"
    elif pacmanpkg.pacman_in_repos(pkgname):
        pkgname = f"deb-{pkgname} (name taken in repos)"
    rows = [
        ("File", str(deb.path)),
        ("Package", deb.name),
        ("Version", deb.version),
        ("Architecture", f"{deb.arch} (-> {mapped_arch})"),
        ("Maintainer", deb.field("Maintainer")),
        ("Homepage", deb.field("Homepage")),
        ("Description", deb.description.strip()),
        ("Depends", deb.field("Depends")),
        ("Recommends", deb.field("Recommends")),
        ("Installed-Size", human_size(deb.installed_size) if deb.installed_size else ""),
        ("Payload", f"{len([m for m in members if m.isfile()])} files, {human_size(total)}"),
        ("Conffiles", ", ".join(deb.conffiles)),
        ("Maintainer scripts", ", ".join(deb.maintainer_scripts)),
        ("Pacman name", pkgname),
    ]
    width = max(len(label) for label, _ in rows)
    for label, value in rows:
        for index, line in enumerate(str(value).splitlines()):
            prefix = f"{label:<{width}}  " if index == 0 else " " * (width + 2)
            print(f"{prefix}{line}")
    return 0


def cmd_deps(args: argparse.Namespace) -> int:
    deb = load_deb(args.deb)
    if deb is None:
        return 1
    resolution = resolve(deb)
    print_dependency_report(resolution, verbose=not args.quiet)
    if args.json:
        print(
            json.dumps(
                {
                    "satisfied": resolution.satisfied,
                    "missing": resolution.missing,
                    "unknown": resolution.unknown,
                    "skipped": resolution.skipped,
                    "installable": resolution.installable,
                },
                indent=2,
            )
        )
    return 1 if resolution.has_problems else 0


def cmd_extract(args: argparse.Namespace) -> int:
    deb = load_deb(args.deb)
    if deb is None:
        return 1
    dest = Path(args.dest) if args.dest else Path.cwd() / f"{deb.name}_{deb.version}"
    extracted = deb.extract_data(dest)
    total = sum(item.size for item in extracted if item.kind == "file")
    ok(f"extracted {len(extracted)} entries ({human_size(total)}) to {dest}")
    return 0


def cmd_convert(args: argparse.Namespace) -> int:
    deb = load_deb(args.deb)
    if deb is None:
        return 1

    if not _check_architecture(deb, args.ignore_arch):
        return 1

    resolution = DepResolution()
    if not args.no_deps:
        resolution = resolve(deb)
        print_dependency_report(resolution, verbose=args.verbose)
    deps = decide_dependencies(
        deb,
        resolution,
        no_deps=args.no_deps,
        install_deps=False,
        strict=args.strict_deps,
        all_deps=args.all_deps,
        assume_yes=True,
    )
    if deps is None:
        return 1

    pkgname = decide_pkgname(deb, args.name)
    output_dir = Path(args.output) if args.output else Path.cwd()
    workdir = Path(tempfile.mkdtemp(prefix="debinstaller-"))
    try:
        root = workdir / "root"
        deb.extract_data(root)
        pkg_info = pacmanpkg.package_info(
            deb,
            name=pkgname,
            deps=deps,
            license_override=pacmanpkg.detect_license(root, deb.name),
        )
        package = pacmanpkg.build_pacman_package(
            root,
            pkg_info,
            output_dir,
            conffiles=deb.conffiles,
            generator=GENERATOR,
        )
        ok(f"created {package}")
        note(
            "install with: "
            + ("" if os.geteuid() == 0 else "sudo ")
            + f"pacman -U {package}"
        )
        return 0
    finally:
        if args.debug:
            warn(f"work directory kept: {workdir}")
        else:
            shutil.rmtree(workdir, ignore_errors=True)


def cmd_install(args: argparse.Namespace) -> int:
    if not python_has_zstd() and not shutil.which("zstd"):
        warn(
            "neither Python zstd support nor the zstd binary is available; "
            "packages will be compressed with xz instead"
        )
    status = 0
    for path in args.deb:
        status |= _install_one(path, args)
    return status


def _check_architecture(deb: DebPackage, ignore: bool) -> bool:
    target = pacmanpkg.map_deb_arch(deb.arch)
    system = pacmanpkg.current_arch()
    if target in ("any", system) or ignore:
        if target not in ("any", system):
            warn(f"architecture mismatch ignored: {deb.arch} on {system}")
        return True
    error(
        f"{deb.path.name}: architecture '{deb.arch}' (maps to '{target}') does not "
        f"match this system ('{system}'); use --ignore-arch to force conversion"
    )
    return False


def _install_one(deb_path: str, args: argparse.Namespace) -> int:
    deb = load_deb(deb_path)
    if deb is None:
        return 1

    info(f"{deb.name} {deb.version} [{deb.arch}]")
    if deb.synopsis:
        note(deb.synopsis)
    if not _check_architecture(deb, args.ignore_arch):
        return 1

    resolution = DepResolution()
    if not args.no_deps:
        resolution = resolve(deb)
        print_dependency_report(resolution, verbose=args.verbose)
    deps = decide_dependencies(
        deb,
        resolution,
        no_deps=args.no_deps,
        install_deps=args.install_deps,
        strict=args.strict_deps,
        all_deps=False,
        assume_yes=args.yes,
    )
    if deps is None:
        return 1

    pkgname = decide_pkgname(deb, args.name)
    output_dir = Path(args.output) if args.output else default_output_dir(installing=True)
    workdir = Path(tempfile.mkdtemp(prefix="debinstaller-"))
    try:
        root = workdir / "root"
        extracted = deb.extract_data(root)
        total = sum(item.size for item in extracted if item.kind == "file")
        note(f"payload: {len(extracted)} entries, {human_size(total)}")

        pkg_info = pacmanpkg.package_info(
            deb,
            name=pkgname,
            deps=deps,
            license_override=pacmanpkg.detect_license(root, deb.name),
        )
        package = pacmanpkg.build_pacman_package(
            root,
            pkg_info,
            output_dir,
            conffiles=deb.conffiles,
            generator=GENERATOR,
        )
        info(f"converted to pacman package: {package}")

        scripts: dict[str, Path] = {}
        try:
            scripts = deb.save_maintainer_scripts(store.scripts_root() / pkg_info.pkgname)
        except OSError as exc:
            warn(f"could not store maintainer scripts: {exc}")
        if scripts:
            note("maintainer scripts found: " + ", ".join(sorted(scripts)))
            if not args.run_scripts:
                note("not running them (pass --run-scripts to execute as root)")

        if args.dry_run:
            ok("dry run complete; nothing installed")
            return 0

        if args.run_scripts and "preinst" in scripts:
            run_maintainer_script(scripts["preinst"], "install", deb.name)

        if pacmanpkg.pacman_binary():
            rc = run_as_root(["pacman", "-U", "--noconfirm", str(package)])
            installed_files: list[str] = []
        else:
            warn("pacman not found; falling back to a plain file copy")
            if root_prefix() is None:
                error("root privileges are required to install files")
                return 1
            copied = fallback_install(root)
            if copied is None:
                return 1
            installed_files = copied
            rc = 0

        if rc != 0:
            error(f"installation failed (pacman exit code {rc})")
            return rc

        if args.run_scripts and "postinst" in scripts:
            run_maintainer_script(scripts["postinst"], "configure", deb.name)

        store.record(
            store.PackageRecord(
                pkgname=pkg_info.pkgname,
                deb_package=deb.name,
                deb_version=deb.version,
                deb_arch=deb.arch,
                deb_file=str(deb.path),
                installed_at=datetime.now(timezone.utc).isoformat(timespec="seconds"),
                scripts=sorted(scripts),
                deps=deps,
                files=installed_files,
                pacman_package=str(package),
                renamed_from=deb.name if pkg_info.renamed else "",
            )
        )
        ok(f"installed {pkg_info.pkgname} {pkg_info.pkgver}-{pkg_info.pkgrel}")
        note(f"remove with: debinstall remove {pkg_info.pkgname}")

        if not args.keep_package:
            try:
                package.unlink()
            except OSError:
                pass
        return 0
    finally:
        if args.debug:
            warn(f"work directory kept: {workdir}")
        else:
            shutil.rmtree(workdir, ignore_errors=True)


def cmd_remove(args: argparse.Namespace) -> int:
    record = store.lookup(args.name)
    if record is None:
        error(
            f"'{args.name}' was not installed by debinstaller "
            "(use 'debinstall list' to see tracked packages)"
        )
        return 1

    scripts_dir = store.scripts_root() / record.pkgname
    if args.run_scripts and (scripts_dir / "prerm").is_file():
        run_maintainer_script(scripts_dir / "prerm", "remove", record.deb_package)

    if pacmanpkg.pacman_binary():
        rc = run_as_root(["pacman", "-R", "--noconfirm", record.pkgname])
    else:
        warn("pacman not found; removing recorded files manually")
        rc = 0
        fallback_remove(record.files)

    if rc != 0:
        error(f"pacman failed to remove {record.pkgname} (exit code {rc})")
        return rc

    if args.run_scripts and (scripts_dir / "postrm").is_file():
        run_maintainer_script(scripts_dir / "postrm", "remove", record.deb_package)

    shutil.rmtree(scripts_dir, ignore_errors=True)
    store.forget(record.pkgname)
    ok(f"removed {record.pkgname}")
    return 0


def cmd_list(args: argparse.Namespace) -> int:
    records = store.load()
    if not records:
        info("no packages installed by debinstaller")
        return 0
    rows = []
    for record in sorted(records.values(), key=lambda r: r.pkgname):
        rows.append((record.pkgname, record.deb_version, record.deb_arch, record.installed_at))
    width = max(len(row[0]) for row in rows)
    for pkgname, version, arch, installed_at in rows:
        print(f"{pkgname:<{width}}  {version:<16} {arch:<8} installed {installed_at}")
    return 0


# ----------------------------------------------------------------- argument parser

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="debinstall",
        description=(
            "Install Debian (.deb) packages on Arch Linux by converting them into "
            "native pacman packages."
        ),
    )
    parser.add_argument("-V", "--version", action="version", version=f"debinstaller {__version__}")
    sub = parser.add_subparsers(dest="command", required=True)

    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("-v", "--verbose", action="store_true", help="more detail")
    common.add_argument("--debug", action="store_true", help="keep temporary directories")

    def add_build_options(p: argparse.ArgumentParser) -> None:
        p.add_argument("-n", "--name", help="override the pacman package name")
        p.add_argument("--no-deps", action="store_true", help="skip dependency analysis")
        p.add_argument("--strict-deps", action="store_true", help="abort on unresolved dependencies")
        p.add_argument("--ignore-arch", action="store_true", help="ignore architecture mismatches")
        p.add_argument("-o", "--output", type=Path, help="output directory for the converted package")

    inst = sub.add_parser("install", parents=[common], help="convert and install .deb packages")
    inst.add_argument("deb", nargs="+", help="path(s) to .deb file(s)")
    add_build_options(inst)
    inst.add_argument("--install-deps", action="store_true", help="install missing Arch dependencies")
    inst.add_argument("--run-scripts", action="store_true", help="run maintainer scripts as root")
    inst.add_argument("--dry-run", action="store_true", help="build the package but do not install")
    inst.add_argument("-y", "--yes", action="store_true", help="assume yes for prompts")
    inst.add_argument("--keep-package", action="store_true", help="keep the converted package file")
    inst.set_defaults(func=cmd_install)

    conv = sub.add_parser("convert", parents=[common], help="convert a .deb into a pacman package only")
    conv.add_argument("deb", help="path to .deb file")
    add_build_options(conv)
    conv.add_argument("--all-deps", action="store_true", help="record every mapped dependency")
    conv.set_defaults(func=cmd_convert)

    deps = sub.add_parser("deps", parents=[common], help="show mapped dependencies of a .deb")
    deps.add_argument("deb", help="path to .deb file")
    deps.add_argument("-q", "--quiet", action="store_true", help="summary only")
    deps.add_argument("--json", action="store_true", help="machine readable output")
    deps.set_defaults(func=cmd_deps)

    inf = sub.add_parser("info", parents=[common], help="show metadata of a .deb")
    inf.add_argument("deb", help="path to .deb file")
    inf.set_defaults(func=cmd_info)

    ext = sub.add_parser("extract", parents=[common], help="extract a .deb payload into a directory")
    ext.add_argument("deb", help="path to .deb file")
    ext.add_argument("dest", nargs="?", help="destination directory")
    ext.set_defaults(func=cmd_extract)

    rem = sub.add_parser("remove", parents=[common], help="remove a package installed by debinstall")
    rem.add_argument("name", help="pacman package name (see 'debinstall list')")
    rem.add_argument("--run-scripts", action="store_true", help="run prerm/postrm as root")
    rem.set_defaults(func=cmd_remove)

    lst = sub.add_parser("list", parents=[common], help="list packages installed by debinstall")
    lst.set_defaults(func=cmd_list)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except KeyboardInterrupt:
        print()
        error("interrupted")
        return 130
