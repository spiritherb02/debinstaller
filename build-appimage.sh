#!/usr/bin/env bash
#
# 把「软件包安装程序」自己打成 .AppImage
#
#   ./build-appimage.sh                 组装 AppDir + 压成 AppImage
#   ./build-appimage.sh --appdir-only   只组装 AppDir，不做 squashfs
#
# 需要两样本脚本**不会**自动下载的东西：
#   1) mksquashfs        —— sudo pacman -S squashfs-tools
#   2) type2 runtime ELF —— AppImageKit 的 runtime-x86_64，放到
#      APPIMAGE_RUNTIME=<路径> 指给它（默认找 ./runtime-x86_64 和 ~/.cache/）
#
# 说清楚一点：打出来的 AppImage **仍然只能在 Arch 系跑**。这个工具的正文是
# shell + Python，运行时要调宿主的 pacman / dpkg-deb / fakeroot，
# 图形界面还要宿主的 python-gobject + gtk3 —— AppImage 装不下这些，
# 它省掉的只是"安装本工具"这一步，不是"换台机器就能跑"。
#
set -euo pipefail

SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUTDIR="$SELF/dist"
NAME="PackageInstaller"
ARCH_TAG=$(uname -m)          # x86_64 / aarch64，runtime 要对应
VERSION=$("$SELF/bin/debinstall" --version 2>/dev/null | awk '{print $NF}')
[ -n "$VERSION" ] || { echo "拿不到版本号，检查 $SELF/bin/debinstall" >&2; exit 1; }

APPDIR_ONLY=0
[ "${1:-}" = "--appdir-only" ] && APPDIR_ONLY=1

CB=$'\e[34m'; CG=$'\e[32m'; CY=$'\e[33m'; C0=$'\e[0m'
step() { printf '%s==>%s %s\n' "$CB" "$C0" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$CG" "$C0" "$*"; }
warn() { printf '  %s!%s %s\n' "$CY" "$C0" "$*"; }

APPDIR="$OUTDIR/$NAME.AppImage"          # AppDir 目录（约定后缀）
TARGET="$OUTDIR/$NAME-$VERSION-$ARCH_TAG.AppImage"

# ── 1. 组装 AppDir ──────────────────────────────────────────────────────
step "组装 $NAME.AppImage/（AppDir）"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/share/applications" \
         "$APPDIR/usr/share/doc/$NAME"

# AppRun 用绝对路径找引擎，占位符留着不动（install.sh 才会替换它）
for f in debinstall deb-install-ui deb-install-open deb-install-askpass deb-install-raw; do
    [ -f "$SELF/bin/$f" ] || { echo "缺 bin/$f" >&2; exit 1; }
    install -m 755 "$SELF/bin/$f" "$APPDIR/usr/bin/$f"
done
ok "usr/bin/ ×5"

install -m 644 "$SELF/README.md" "$APPDIR/usr/share/doc/$NAME/README.md"
[ -f "$SELF/LICENSE" ] && install -m 644 "$SELF/LICENSE" "$APPDIR/usr/share/doc/$NAME/LICENSE"

# AppRun：AppImage 的入口。把 DEB_INSTALL_TOOL 指到镜像内的引擎，
# 图形界面就不去找宿主 PATH 上的旧版本了。
cat > "$APPDIR/AppRun" <<'RUN'
#!/usr/bin/env sh
# AppImage 入口：永远用镜像里那一份引擎，别掉到宿主的 PATH 上。
here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
export DEB_INSTALL_TOOL="$here/usr/bin/debinstall"
exec "$here/usr/bin/deb-install-ui" "$@"
RUN
chmod 755 "$APPDIR/AppRun"
ok "AppRun（导出 DEB_INSTALL_TOOL 后启动图形界面）"

# 桌面入口：AppImage 约定根目录放一份，本工具自己的 AppImage 扫描器
# 只看 usr/share/applications/，所以两份都要。
DESK_SRC="$SELF/share/applications/deb-install.desktop"
sed 's|^Exec=.*|Exec=./AppRun %F|' "$DESK_SRC" > "$APPDIR/$NAME.desktop"
sed 's|^Exec=.*|Exec=./AppRun %F|' "$DESK_SRC" > "$APPDIR/usr/share/applications/$NAME.desktop"
chmod 644 "$APPDIR/$NAME.desktop" "$APPDIR/usr/share/applications/$NAME.desktop"
ok "$NAME.desktop ×2（根目录 + usr/share/applications）"

# 图标：本工具的 desktop 用的是主题图标（system-software-install），
# AppImage 得自带一张，否则双击后菜单里是通用图标。
_pick_icon() {
    local c
    for c in "$SELF/appimage-icon.svg" "$SELF/appimage-icon.png"; do
        [ -f "$c" ] && { printf '%s' "$c"; return; }
    done
    # 宿主主题里的同名图标：SVG 优先（本工具的扫描器也认 SVG）
    for c in /usr/share/icons/breeze/apps/48/system-software-install.svg \
             /usr/share/icons/pearOS/apps/scalable/system-software-install.svg \
             /usr/share/icons/hicolor/256x256/apps/system-software-install.png \
             /usr/share/icons/Adwaita/48x48/apps/system-software-install.png; do
        [ -f "$c" ] && { printf '%s' "$c"; return; }
    done
}
ICON=$(_pick_icon || true)
if [ -n "$ICON" ]; then
    case "$ICON" in
        *.svg) SIZE=scalable; EXT=svg ;;
        *)     SIZE=$(basename "$(dirname "$(dirname "$ICON")")"); EXT=png ;;
    esac
    mkdir -p "$APPDIR/usr/share/icons/hicolor/$SIZE/apps"
    install -m 644 "$ICON" "$APPDIR/usr/share/icons/hicolor/$SIZE/apps/$NAME.$EXT"
    cp "$ICON" "$APPDIR/.DirIcon"
    sed -i "s|^Icon=.*|Icon=$NAME|" "$APPDIR/$NAME.desktop" \
                                     "$APPDIR/usr/share/applications/$NAME.desktop"
    ok "图标 $(basename "$ICON") → hicolor/$SIZE/apps/$NAME.$EXT + .DirIcon"
else
    warn "找不到可用图标，菜单里会是通用图标（放一张 appimage-icon.png 到 $SELF 再重跑）"
fi

# ── 2. 要不要到此为止 ───────────────────────────────────────────────────
if [ $APPDIR_ONLY -eq 1 ]; then
    ok "--appdir-only：AppDir 在 $APPDIR"
    exit 0
fi

# ── 3. 压成 squashfs + 拼 runtime ───────────────────────────────────────
step "压缩成 type-2 AppImage"

RT=""
for c in "${APPIMAGE_RUNTIME:-}" "$SELF/runtime-$ARCH_TAG" "$HOME/.cache/appimagetool/runtime-$ARCH_TAG"; do
    [ -n "$c" ] && [ -f "$c" ] && { RT=$c; break; }
done
if [ -z "$RT" ]; then
    warn "缺少 type-2 runtime（AppImage 的 ELF 头）"
    echo
    echo "  补齐这两样之后再跑一次："
    echo "    sudo pacman -S squashfs-tools"
    echo "    # runtime-x86_64 从 AppImageKit 的 release 里取，自己核对校验和："
    echo "    #   https://github.com/AppImage/AppImageKit/releases"
    echo "    export APPIMAGE_RUNTIME=/你的路径/runtime-$ARCH_TAG"
    exit 3
fi

command -v mksquashfs >/dev/null 2>&1 || {
    warn "没有 mksquashfs（sudo pacman -S squashfs-tools）"
    exit 3
}

rm -f "$TARGET"
SQ=$(mktemp --suffix=.squashfs)
trap 'rm -f "$SQ"' EXIT
mksquashfs "$APPDIR" "$SQ" -root-owned -noappend -comp zstd -b 1M -no-xattrs >/dev/null
# type-2 = ELF runtime 在前，squashfs 拼在后面
cat "$RT" "$SQ" > "$TARGET"
chmod +x "$TARGET"
ok "$TARGET"

( cd "$OUTDIR" && sha256sum "$(basename "$TARGET")" > "$(basename "$TARGET").sha256" )
ok "$TARGET.sha256"

echo
echo "  自检："
file -b "$TARGET" | sed 's/^/    /'
echo
echo "  试用（不安装）：  ./$TARGET --appimage-extract-and-run"
echo "  塞进自己的菜单：  双击它，用本工具的 .AppImage 分支移入 ~/Applications"
