"""Best-effort mapping of Debian dependencies to Arch Linux packages."""

from __future__ import annotations

import os
import re
import shutil
import subprocess
from dataclasses import dataclass, field

from .debfile import DebPackage, DepAlternative

# Debian runtime dependencies that have no meaning on Arch (or are always
# available) and should not be turned into pacman dependencies.
SKIP = {
    "base-files",
    "base-passwd",
    "debconf",
    "debconf-2.0",
    "debianutils",
    "dpkg",
    "dpkg-dev",
    "gcc-12-base",
    "gcc-13-base",
    "gcc-14-base",
    "init-system-helpers",
    "install-info",
    "libc-bin",
    "libc-l10n",
    "locales",
    "lsb-base",
    "mawk",
    "media-types",
    "mime-support",
    "multiarch-support",
    "perl-base",
    "sensible-utils",
    "sysv-rc",
    "sysvinit-utils",
    "ucf",
    "usr-is-merged",
}

# Debian package -> Arch package. Additions are welcome; this is where most
# of the magic (and the maintenance burden) lives.
MAP: dict[str, str] = {
    # core / C
    "libc6": "glibc",
    "libc6-dev": "glibc",
    "libgcc-s1": "gcc-libs",
    "libgcc1": "gcc-libs",
    "libstdc++6": "gcc-libs",
    "libstdc++6-dev": "gcc-libs",
    "libgomp1": "gcc-libs",
    "libatomic1": "gcc-libs",
    "libasan8": "gcc-libs",
    "zlib1g": "zlib",
    "liblzma5": "xz",
    "xz-utils": "xz",
    "libbz2-1.0": "bzip2",
    "libzstd1": "zstd",
    "liblzo2-2": "lzo",
    "libz-ng2": "zlib-ng",
    "libfuse2": "fuse2",
    "libfuse3-3": "fuse3",
    "libcap2": "libcap",
    "libattr1": "attr",
    "libacl1": "acl",
    "libselinux1": "libselinux",
    "libseccomp2": "libseccomp",
    "libaudit1": "audit",
    "libpam0g": "pam",
    "libsystemd0": "systemd-libs",
    "libudev1": "systemd-libs",
    "libmount1": "util-linux-libs",
    "libblkid1": "util-linux-libs",
    "libuuid1": "util-linux-libs",
    "libfdisk1": "util-linux-libs",
    "libsmartcols1": "util-linux-libs",
    "libcom-err2": "e2fsprogs",
    "libext2fs2": "e2fsprogs",
    "libss2": "e2fsprogs",
    # crypto / tls
    "ca-certificates": "ca-certificates",
    "openssl": "openssl",
    "libssl3": "openssl",
    "libssl3t64": "openssl",
    "libcrypto3": "openssl",
    "libgcrypt20": "libgcrypt",
    "libgpg-error0": "libgpg-error",
    "libgnutls30": "gnutls",
    "libnettle8": "nettle",
    "libhogweed6": "nettle",
    "libgmp10": "gmp",
    "libsasl2-2": "libsasl",
    "libldap-2.5-0": "libldap",
    "libkrb5-3": "krb5",
    "libgssapi-krb5-2": "krb5",
    "libkeyutils1": "keyutils",
    "libdb5.3": "db",
    "libsqlite3-0": "sqlite",
    # compression / archive
    "libarchive13": "libarchive",
    "libzip4": "libzip",
    "unzip": "unzip",
    "zip": "zip",
    "p7zip-full": "p7zip",
    # GLib / GTK stack
    "libglib2.0-0": "glib2",
    "libgio-2.0-0": "glib2",
    "libgobject-2.0-0": "glib2",
    "libgmodule-2.0-0": "glib2",
    "libgdk-pixbuf-2.0-0": "gdk-pixbuf2",
    "libgtk-3-0": "gtk3",
    "libgtk-4-1": "gtk4",
    "libgtk2.0-0": "gtk2",
    "libatk1.0-0": "atk",
    "libatk-bridge2.0-0": "at-spi2-core",
    "libatspi2.0-0": "at-spi2-core",
    "libpango-1.0-0": "pango",
    "libpangocairo-1.0-0": "pango",
    "libcairo2": "cairo",
    "libcairo-gobject2": "cairo",
    "libharfbuzz0b": "harfbuzz",
    "libfribidi0": "fribidi",
    "libthai0": "libthai",
    "libdatrie1": "libdatrie",
    "libpcre3": "pcre",
    "libpcre2-8-0": "pcre2",
    "libffi8": "libffi",
    "libjson-glib-1.0-0": "json-glib",
    "libsoup2.4-1": "libsoup",
    "libsoup-3.0-0": "libsoup3",
    "libnotify4": "libnotify",
    "gir1.2-gtk-3.0": "gtk3",
    "gir1.2-glib-2.0": "glib2",
    # Qt
    "libqt5core5a": "qt5-base",
    "libqt5gui5": "qt5-base",
    "libqt5widgets5": "qt5-base",
    "libqt5dbus5": "qt5-base",
    "libqt5network5": "qt5-base",
    "libqt5svg5": "qt5-svg",
    "libqt5x11extras5": "qt5-x11extras",
    "libqt6core6": "qt6-base",
    "libqt6gui6": "qt6-base",
    "libqt6widgets6": "qt6-base",
    "libqt6dbus6": "qt6-base",
    "libqt6network6": "qt6-base",
    "libqt6svg6": "qt6-svg",
    "qml-module-qtquick2": "qt6-declarative",
    "qml-module-qtquick-controls2": "qt6-declarative",
    "qml-module-qtgraphicaleffects": "qt5-graphicaleffects",
    # X11 / Wayland / graphics
    "libx11-6": "libx11",
    "libx11-xcb1": "libx11",
    "libxcb1": "libxcb",
    "libxext6": "libxext",
    "libxrender1": "libxrender",
    "libxi6": "libxi",
    "libxfixes3": "libxfixes",
    "libxcursor1": "libxcursor",
    "libxinerama1": "libxinerama",
    "libxrandr2": "libxrandr",
    "libxcomposite1": "libxcomposite",
    "libxdamage1": "libxdamage",
    "libxtst6": "libxtst",
    "libxss1": "libxss",
    "libxkbfile1": "libxkbfile",
    "libxkbcommon0": "libxkbcommon",
    "libxkbcommon-x11-0": "libxkbcommon-x11",
    "libgl1": "mesa",
    "libglx0": "mesa",
    "libegl1": "mesa",
    "libgles2": "mesa",
    "libgbm1": "mesa",
    "libglu1-mesa": "glu",
    "libdrm2": "libdrm",
    "libepoxy0": "libepoxy",
    "libwayland-client0": "wayland",
    "libwayland-cursor0": "wayland",
    "libwayland-egl1": "wayland",
    "libvulkan1": "vulkan-icd-loader",
    "libva2": "libva",
    "libvdpau1": "libvdpau",
    # fonts / images / media
    "fontconfig": "fontconfig",
    "libfontconfig1": "fontconfig",
    "libfreetype6": "freetype2",
    "libpng16-16": "libpng",
    "libjpeg62-turbo": "libjpeg-turbo",
    "libjpeg8": "libjpeg-turbo",
    "libtiff5": "libtiff",
    "libtiff6": "libtiff",
    "libwebp7": "libwebp",
    "libwebpdemux2": "libwebp",
    "libwebpmux3": "libwebp",
    "libgif7": "giflib",
    "libopenjp2-7": "openjpeg2",
    "libgsf-1-114": "libgsf",
    "librsvg2-2": "librsvg",
    "libavcodec58": "ffmpeg",
    "libavcodec59": "ffmpeg",
    "libavcodec60": "ffmpeg",
    "libavformat58": "ffmpeg",
    "libavformat59": "ffmpeg",
    "libavformat60": "ffmpeg",
    "libavutil56": "ffmpeg",
    "libavutil57": "ffmpeg",
    "libavutil58": "ffmpeg",
    "libswresample3": "ffmpeg",
    "libswresample4": "ffmpeg",
    "libswscale5": "ffmpeg",
    "libswscale6": "ffmpeg",
    "gstreamer1.0-libav": "gst-libav",
    "gstreamer1.0-plugins-base": "gst-plugins-base",
    "gstreamer1.0-plugins-good": "gst-plugins-good",
    "gstreamer1.0-plugins-bad": "gst-plugins-bad",
    "gstreamer1.0-plugins-ugly": "gst-plugins-ugly",
    "libgstreamer1.0-0": "gstreamer",
    "libgstreamer-plugins-base1.0-0": "gst-plugins-base-libs",
    "libasound2": "alsa-lib",
    "libasound2t64": "alsa-lib",
    "libpulse0": "libpulse",
    "libpulse-mainloop-glib0": "libpulse",
    "libjack-jackd2-0": "jack2",
    "libsndfile1": "libsndfile",
    "libvorbis0a": "libvorbis",
    "libvorbisfile3": "libvorbis",
    "libogg0": "libogg",
    "libflac12": "flac",
    "libflac8": "flac",
    "libopus0": "opus",
    "libmp3lame0": "lame",
    "libmpg123-0": "mpg123",
    "libsamplerate0": "libsamplerate",
    "libspeex1": "speex",
    "libtheora0": "libtheora",
    # DBus / misc libs
    "libdbus-1-3": "dbus",
    "dbus": "dbus",
    "libexpat1": "expat",
    "libxml2": "libxml2",
    "libxslt1.1": "libxslt",
    "libyaml-0-2": "libyaml",
    "libssh2-1": "libssh2",
    "libssh-4": "libssh",
    "libcurl4": "curl",
    "libcurl3-gnutls": "curl",
    "libcurl4-openssl-dev": "curl",
    "libreadline8": "readline",
    "libtinfo6": "ncurses",
    "libncursesw6": "ncurses",
    "libncurses6": "ncurses",
    "libedit2": "libedit",
    "libgdbm6": "gdbm",
    "libgdbm-compat4": "gdbm",
    "libexiv2-27": "exiv2",
    "libraw20": "libraw",
    "libpoppler-glib8": "poppler-glib",
    "libsecret-1-0": "libsecret",
    "libjsoncpp25": "jsoncpp",
    "libtinyxml2-10": "tinyxml2",
    "libprotobuf32": "protobuf",
    "libprotobuf-lite32": "protobuf",
    "libnl-3-200": "libnl",
    "libnl-genl-3-200": "libnl",
    "libusb-1.0-0": "libusb",
    "libpci3": "pciutils",
    "libpciaccess0": "libpciaccess",
    "libnuma1": "numactl",
    "libunwind8": "libunwind",
    "libdw1": "elfutils",
    "libelf1": "libelf",
    "libjson-c5": "json-c",
    "libconfig9": "libconfig",
    "libinotifytools0": "inotify-tools",
    "libutempter0": "libutempter",
    "libcap-ng0": "libcap-ng",
    "libapparmor1": "libapparmor",
    "libcups2": "libcups",
    "libcups2t64": "libcups",
    "cups-common": "libcups",
    "libnss3": "nss",
    "libnspr4": "nspr",
    "libnspr4-0d": "nspr",
    "libcairo2-dev": "cairo",
    # desktop integration
    "desktop-file-utils": "desktop-file-utils",
    "shared-mime-info": "shared-mime-info",
    "hicolor-icon-theme": "hicolor-icon-theme",
    "xdg-utils": "xdg-utils",
    "xdg-user-dirs": "xdg-user-dirs",
    "xdg-desktop-portal": "xdg-desktop-portal",
    "xdg-desktop-portal-gtk": "xdg-desktop-portal-gtk",
    "xdg-desktop-portal-gnome": "xdg-desktop-portal-gnome",
    "gnome-keyring": "gnome-keyring",
    "libayatana-appindicator3-1": "libayatana-appindicator",
    "libappindicator3-1": "libappindicator-gtk3",
    "default-dbus-session-bus": "dbus",
    "dbus-x11": "dbus",
    # python / perl / java
    "python3": "python",
    "python3-minimal": "python",
    "python3-tk": "tk",
    "python3-gi": "python-gobject",
    "python3-cairo": "python-cairo",
    "python3-dbus": "python-dbus",
    "python3-pil": "python-pillow",
    "python3-yaml": "python-yaml",
    "python3-requests": "python-requests",
    "python3-numpy": "python-numpy",
    "python3-pyqt5": "python-pyqt5",
    "python3-pyqt6": "python-pyqt6",
    "python3-setuptools": "python-setuptools",
    "python3-pip": "python-pip",
    "python3-venv": "python-virtualenv",
    "default-jre": "jre-openjdk",
    "default-jre-headless": "jre-openjdk-headless",
    "openjdk-17-jre": "jre17-openjdk",
    "openjdk-17-jre-headless": "jre17-openjdk-headless",
    "openjdk-21-jre": "jre21-openjdk",
    "openjdk-21-jre-headless": "jre21-openjdk-headless",
    # common tools
    "bash": "bash",
    "coreutils": "coreutils",
    "grep": "grep",
    "sed": "sed",
    "gawk": "gawk",
    "gzip": "gzip",
    "bzip2": "bzip2",
    "tar": "tar",
    "curl": "curl",
    "wget": "wget",
    "git": "git",
    "ffmpeg": "ffmpeg",
    "sqlite3": "sqlite",
    "vim": "vim",
    "less": "less",
    "procps": "procps-ng",
    "psmisc": "psmisc",
    "findutils": "findutils",
    "gpg": "gnupg",
    "gnupg": "gnupg",
    "dirmngr": "gnupg",
    "patch": "patch",
    "rsync": "rsync",
    "openssh-client": "openssh",
    "sudo": "sudo",
    "util-linux": "util-linux",
    "util-linux-extra": "util-linux",
    "systemd": "systemd",
    "kmod": "kmod",
    "udev": "systemd",
    "policykit-1": "polkit",
    "pkexec": "polkit",
    "zenity": "zenity",
    "kdialog": "kdialog",
    "mesa-utils": "mesa-utils",
    "vulkan-tools": "vulkan-tools",
    "fonts-liberation": "ttf-liberation",
    "fonts-noto-cjk": "noto-fonts-cjk",
    "fonts-noto-color-emoji": "noto-fonts-emoji",
    "fonts-dejavu-core": "ttf-dejavu",
    "fonts-wqy-zenhei": "wqy-zenhei",
}

# Packages known to live in the AUR (or nowhere) on Arch; we do not try to
# install these automatically, but we still report them.
KNOWN_UNAVAILABLE = {
    "libssl1.1",
    "libicu70",
    "libicu72",
    "libqt5-webkit",
}

_DEBIAN_LIB_RE = re.compile(r"^lib[a-z0-9+.-]+?\d*$")
_DEV_SUFFIX_RE = re.compile(r"-dev$")


@dataclass
class DepCandidate:
    deb_name: str
    arch_name: str
    confidence: str  # mapped | heuristic | same | skipped
    status: str = "unknown"  # satisfied | missing | skipped | unknown

    def __str__(self) -> str:
        return f"{self.deb_name} -> {self.arch_name}" if self.arch_name else self.deb_name


@dataclass
class DepGroup:
    deb_names: list[str]
    candidates: list[DepCandidate] = field(default_factory=list)


@dataclass
class DepResolution:
    groups: list[DepGroup] = field(default_factory=list)
    satisfied: list[str] = field(default_factory=list)
    missing: list[str] = field(default_factory=list)
    skipped: list[str] = field(default_factory=list)
    unknown: list[str] = field(default_factory=list)

    @property
    def installable(self) -> list[str]:
        return sorted(set(self.satisfied) | set(self.missing))

    @property
    def has_problems(self) -> bool:
        return bool(self.missing or self.unknown)

    def render(self) -> str:
        lines = []
        for group in self.groups:
            alts = " | ".join(str(c) for c in group.candidates)
            status = group.candidates[0].status if group.candidates else "unknown"
            lines.append(f"  [{status:>9}] {alts}")
        return "\n".join(lines)


def map_name(deb_name: str) -> tuple[str | None, str]:
    """Map a single Debian package name.

    Returns ``(arch_name_or_None, confidence)``.  ``confidence`` is one of
    ``mapped``, ``heuristic``, ``same`` or ``skipped``.
    """
    name = deb_name.split(":", 1)[0].lower()

    if name in SKIP:
        return None, "skipped"
    if name in MAP:
        return MAP[name], "mapped"
    if name in KNOWN_UNAVAILABLE:
        return name, "mapped"

    # python3-foo -> python-foo
    if name.startswith("python3-") and len(name) > len("python3-"):
        return "python-" + name[len("python3-") :], "heuristic"

    # libfoo-dev -> foo (Arch ships development files in the base package)
    if _DEV_SUFFIX_RE.search(name):
        base = _DEV_SUFFIX_RE.sub("", name)
        if base in MAP:
            return MAP[base], "heuristic"
        stripped = re.sub(r"\d+$", "", base)
        if stripped in MAP:
            return MAP[stripped], "heuristic"
        return (stripped or base), "heuristic"

    if name in ("pkg-config", "pkgconf"):
        return "pkgconf", "heuristic"

    # Debian soname style libs (libfoo1, libfoo-1.0-0) are unlikely to exist
    # under the same name on Arch.
    if _DEBIAN_LIB_RE.match(name):
        return None, "unknown"

    return name, "same"


def _pacman() -> str | None:
    return shutil.which("pacman")


def _run(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    env = dict(os.environ, LC_ALL="C")
    return subprocess.run(cmd, capture_output=True, text=True, env=env)


def _check_installed(names: set[str]) -> tuple[set[str], set[str]]:
    """Return (satisfied, unsatisfied) using ``pacman -T``."""
    if not names or not _pacman():
        return set(), set(names)
    result = _run([_pacman(), "-T", *sorted(names)])
    if result.returncode == 0:
        return set(names), set()
    missing = {line.strip() for line in result.stdout.splitlines() if line.strip()}
    return set(names) - missing, missing


def _available_in_repos(names: set[str]) -> set[str]:
    """Return the subset of *names* that exists in the sync databases."""
    if not names or not _pacman():
        return set()
    result = _run([_pacman(), "-Si", *sorted(names)])
    available: set[str] = set()
    for block in result.stdout.split("\n\n"):
        for line in block.splitlines():
            if line.startswith("Name") and ":" in line:
                value = line.split(":", 1)[1].strip()
                if value in names:
                    available.add(value)
    return available


def resolve(deb: DebPackage) -> DepResolution:
    """Classify all dependencies of *deb* against the local system."""
    resolution = DepResolution()
    candidates: dict[str, DepCandidate] = {}

    for alternatives in deb.dependency_groups():
        group = DepGroup(deb_names=[a.name for a in alternatives])
        for alt in alternatives:
            arch_name, confidence = map_name(alt.name)
            candidate = DepCandidate(alt.name, arch_name or "", confidence)
            group.candidates.append(candidate)
            if arch_name:
                candidates.setdefault(arch_name, candidate)
        resolution.groups.append(group)

    satisfied, unsatisfied = _check_installed(set(candidates))
    available = _available_in_repos(unsatisfied)

    seen: dict[str, set[str]] = {
        "satisfied": set(),
        "missing": set(),
        "skipped": set(),
        "unknown": set(),
    }

    for group in resolution.groups:
        statuses = []
        for candidate in group.candidates:
            if candidate.confidence == "skipped":
                candidate.status = "skipped"
            elif candidate.arch_name in satisfied:
                candidate.status = "satisfied"
            elif candidate.arch_name in available:
                candidate.status = "missing"
            elif candidate.confidence in ("mapped", "heuristic"):
                # Mapped, but neither installed nor present in the repos.
                candidate.status = "missing" if candidate.arch_name not in KNOWN_UNAVAILABLE else "unknown"
            else:
                candidate.status = "unknown"
            statuses.append(candidate.status)
            if candidate.status == "skipped":
                seen["skipped"].add(candidate.deb_name)
            elif candidate.arch_name:
                seen[candidate.status].add(candidate.arch_name)
            elif candidate.confidence == "unknown":
                seen["unknown"].add(candidate.deb_name)
        # ``candidates`` need no rewrite; group status is derived on render.

    for key in ("satisfied", "missing", "skipped", "unknown"):
        setattr(resolution, key, sorted(seen[key]))
    return resolution
