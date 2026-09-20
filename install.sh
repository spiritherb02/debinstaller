#!/usr/bin/env bash
#
# debinstall —— 在 Arch Linux 上安装 Debian .deb 包的成套工具
# 安装脚本
#
#   ./install.sh                      装到 ~/.local（不需要 root）
#   PREFIX=/usr/local ./install.sh    装到系统目录（可能需要 root）
#   ./install.sh --no-mime            不注册 .deb 双击关联
#   ./install.sh --no-skill           不安装 WorkBuddy 技能文档
#   ./install.sh --dry-run            只显示会做什么，不实际改动
#
set -euo pipefail

VERSION="__VERSION__"
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PREFIX="${PREFIX:-$HOME/.local}"
DO_MIME=1
DO_SKILL=1
DRY_RUN=0

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    CR=$'\e[31m'; CG=$'\e[32m'; CY=$'\e[33m'; CB=$'\e[34m'; CD=$'\e[2m'; C0=$'\e[0m'
else
    CR=; CG=; CY=; CB=; CD=; C0=
fi
step() { printf '%s==>%s %s\n' "$CB" "$C0" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$CG" "$C0" "$*"; }
warn() { printf '  %s!%s %s\n' "$CY" "$C0" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$CR" "$C0" "$*"; }
die()  { printf '%s==>%s %s\n' "$CR" "$C0" "$*" >&2; exit 1; }

usage() {
    sed -n '3,13p' "$0" | sed 's/^# \{0,1\}//'
    echo
    echo "环境变量："
    echo "  PREFIX    安装前缀，默认 \$HOME/.local（会被写成绝对路径）"
    echo
    echo "卸载：$PREFIX/share/debinstall/uninstall.sh"
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)     shift; PREFIX="${1:-}" ;;
        --no-mime)    DO_MIME=0 ;;
        --no-skill)   DO_SKILL=0 ;;
        --dry-run)    DRY_RUN=1 ;;
        -h|--help)    usage ;;
        *)            die "未知参数：$1（用 --help 看用法）" ;;
    esac
    shift
done

[ -n "$PREFIX" ] || die "PREFIX 不能为空"

BIN_DIR="$PREFIX/bin"
APP_DIR="$PREFIX/share/applications"
DOC_DIR="$PREFIX/share/debinstall"
SKILL_DIR="$HOME/.workbuddy/skills/arch-install-deb"
MANIFEST="$DOC_DIR/manifest.txt"

printf '\n%sdebinstall %s%s —— 安装到 %s%s%s\n\n' "$CB" "$VERSION" "$C0" "$CD" "$PREFIX" "$C0"

# ── 0. 源文件自检 ───────────────────────────────────────────────────────
[ -f "$SRC/bin/debinstall" ] || die "找不到 bin/debinstall，请在解压后的目录里运行本脚本"
for f in debinstall deb-install-ui deb-install-open deb-install-askpass deb-install-raw; do
    [ -f "$SRC/bin/$f" ] || die "发布包不完整，缺 bin/$f"
done

# ── 1. 平台检查 ─────────────────────────────────────────────────────────
step "平台检查"
if ! command -v pacman >/dev/null 2>&1; then
    bad "这台机器上没有 pacman，看起来不是 Arch Linux"
    echo "      这个工具靠 pacman 安装转出来的包，非 Arch 系统无法使用。"
    exit 1
fi
ok "Arch Linux（pacman 就位）"

# ── 2. 依赖检查 ─────────────────────────────────────────────────────────
step "依赖检查"

MISSING=()
_need() {   # $1=命令  $2=Arch 包名
    command -v "$1" >/dev/null 2>&1 || MISSING+=("$2")
}

# 核心功能必需
_need dpkg-deb  dpkg
_need bsdtar    libarchive
_need fakeroot  fakeroot
_need zstd      zstd
_need readelf   binutils
_need ar        binutils
_need tar       tar

# 可选（缺了只是少个便利功能，不影响安装）
OPT_MISSING=()
_opt() { command -v "$1" >/dev/null 2>&1 || OPT_MISSING+=("$2"); }
_opt update-desktop-database desktop-file-utils
_opt gtk-update-icon-cache   gtk-update-icon-cache
_opt xdg-user-dir            xdg-user-dirs
_opt pkexec                  polkit

if [ ${#MISSING[@]} -gt 0 ]; then
    # 去重
    PKGS=$(printf '%s\n' "${MISSING[@]}" | sort -u | tr '\n' ' ')
    bad "缺少必需组件，请先安装："
    printf '      sudo pacman -S %s\n' "${PKGS% }"
    exit 1
fi
ok "核心依赖齐全（dpkg / libarchive / fakeroot / zstd / binutils）"

if [ ${#OPT_MISSING[@]} -gt 0 ]; then
    PKGS=$(printf '%s\n' "${OPT_MISSING[@]}" | sort -u | tr '\n' ' ')
    warn "可选组件缺失（不影响使用）：${PKGS% }"
fi

# GUI 依赖
# 注意：图形脚本的 shebang 是 /usr/bin/python3（系统 python，gi 装在它下面）。
# 这里必须用同一个解释器检测，不能用 PATH 里的 python3 —— 可能是某个
# venv/conda 的 python，没有 gi，会误判成"图形界面不可用"。
GUI_OK=0
GUI_PY=$(head -1 "$SRC/bin/deb-install-ui" 2>/dev/null | sed 's|^#!||' | awk '{print $1}')
case "$GUI_PY" in
    /*) ;;
    *)  GUI_PY=/usr/bin/python3 ;;
esac
[ -x "$GUI_PY" ] || GUI_PY=/usr/bin/python3

if [ -x "$GUI_PY" ] &&
   "$GUI_PY" -c 'import gi; gi.require_version("Gtk","3.0"); from gi.repository import Gtk' 2>/dev/null; then
    GUI_OK=1
    ok "图形界面依赖齐全（$GUI_PY + gi/gtk3）"
else
    warn "图形界面不可用（$GUI_PY 缺 python-gobject / gtk3），命令行部分照常可用"
    printf '      需要图形界面的话：sudo pacman -S python-gobject gtk3\n'
fi

# ── 3. 写入权限 ─────────────────────────────────────────────────────────
step "准备目标目录"
NEED_ROOT=0

_mkdir() {   # 确保目录存在且可写
    local d=$1
    [ -d "$d" ] && [ -w "$d" ] && return 0
    if [ -d "$d" ]; then
        NEED_ROOT=1
        [ $DRY_RUN -eq 1 ] || sudo mkdir -p "$d"
    else
        # 向上找到第一个存在的祖先，判断是否可写
        local p=$d
        while [ ! -e "$p" ] && [ "$p" != "/" ]; do p=$(dirname "$p"); done
        if [ -w "$p" ]; then
            [ $DRY_RUN -eq 1 ] || mkdir -p "$d"
        else
            NEED_ROOT=1
            [ $DRY_RUN -eq 1 ] || sudo mkdir -p "$d"
        fi
    fi
    return 0
}

if [ $DRY_RUN -eq 0 ]; then
    _mkdir "$BIN_DIR"
    _mkdir "$APP_DIR"
    _mkdir "$DOC_DIR"
fi

if [ $NEED_ROOT -eq 1 ]; then
    warn "$PREFIX 需要管理员权限，已用 sudo 创建目录（后面若还提示输密码属正常）"
else
    ok "目录就绪"
fi

AS_ROOT=""
[ $NEED_ROOT -eq 1 ] && [ $DRY_RUN -eq 0 ] && AS_ROOT="sudo"

# ── 4. 安装文件 ─────────────────────────────────────────────────────────
step "安装文件"

if [ $DRY_RUN -eq 1 ]; then
    echo "      （--dry-run，以下仅为预览）"
fi

FILES=()

_put() {   # $1=源  $2=目标  $3=模式
    if [ $DRY_RUN -eq 0 ]; then
        $AS_ROOT install -m "$3" "$1" "$2"
    fi
    FILES+=("$2")
    printf '      %s\n' "$2"
}

for f in debinstall deb-install-ui deb-install-open deb-install-askpass deb-install-raw; do
    _put "$SRC/bin/$f" "$BIN_DIR/$f" 755
done
ok "命令行与图形程序已就位"

# deb-install 作为 debinstall 的别名（GUI、desktop、脚本里都按这个名字找）
if [ $DRY_RUN -eq 0 ]; then
    $AS_ROOT ln -sfn debinstall "$BIN_DIR/deb-install"
fi
FILES+=("$BIN_DIR/deb-install")
ok "别名 deb-install → debinstall"

# ── 5. 图形界面路径占位符 ───────────────────────────────────────────────
step "适配安装路径"
if [ $DRY_RUN -eq 0 ]; then
    if grep -q '@PREFIX_BIN@' "$BIN_DIR/deb-install-ui" 2>/dev/null; then
        $AS_ROOT sed -i "s|@PREFIX_BIN@|$BIN_DIR|g" "$BIN_DIR/deb-install-ui"
    fi
fi
ok "图形界面已记住主程序位置（$BIN_DIR/deb-install）"

# ── 6. 桌面入口 ─────────────────────────────────────────────────────────
if [ $GUI_OK -eq 1 ]; then
    step "安装桌面入口"
    if [ $DRY_RUN -eq 0 ]; then
        # 把 Exec 写成绝对路径：非标准 PREFIX 也能正常工作
        sed "s|^Exec=deb-install-ui|Exec=$BIN_DIR/deb-install-ui|" \
            "$SRC/share/applications/deb-install.desktop" > /tmp/.debinstall-desktop.$$
        $AS_ROOT install -m 644 /tmp/.debinstall-desktop.$$ "$APP_DIR/deb-install.desktop"
        rm -f /tmp/.debinstall-desktop.$$
    fi
    FILES+=("$APP_DIR/deb-install.desktop")
    printf '      %s\n' "$APP_DIR/deb-install.desktop"

    if [ $DO_MIME -eq 1 ] && [ $DRY_RUN -eq 0 ]; then
        command -v update-desktop-database >/dev/null 2>&1 &&
            update-desktop-database "$APP_DIR" >/dev/null 2>&1 || true
        if command -v xdg-mime >/dev/null 2>&1; then
            # .deb 走引擎分析安装，.AppImage 走"移入 ~/Applications + 注册菜单"
            for mime in application/vnd.debian.binary-package application/vnd.appimage; do
                case "$mime" in
                    *deb*) label=".deb" ;;
                    *)     label=".AppImage" ;;
                esac
                xdg-mime default deb-install.desktop "$mime" 2>/dev/null || true
                CUR=$(xdg-mime query default "$mime" 2>/dev/null || true)
                if [ "$CUR" = "deb-install.desktop" ]; then
                    ok "$label 双击默认打开方式已设为 deb-install"
                else
                    warn "$label 关联未生效（当前是 ${CUR:-无}）。可能被别的程序占用，手动指定："
                    printf '      xdg-mime default deb-install.desktop %s\n' "$mime"
                fi
            done
        fi
    elif [ $DO_MIME -eq 0 ]; then
        warn "按 --no-mime 跳过 .deb / .AppImage 关联"
    fi
else
    step "跳过桌面入口"
    warn "图形依赖不全，不安装 .desktop"
fi

# ── 7. 技能文档（可选） ─────────────────────────────────────────────────
if [ $DO_SKILL -eq 1 ] && [ -f "$SRC/share/doc/SKILL.md" ]; then
    step "安装 WorkBuddy 技能文档"
    if [ $DRY_RUN -eq 0 ]; then
        mkdir -p "$SKILL_DIR"
        install -m 644 "$SRC/share/doc/SKILL.md" "$SKILL_DIR/SKILL.md"
    fi
    FILES+=("$SKILL_DIR/SKILL.md")
    ok "$SKILL_DIR/SKILL.md"
    printf '      %s（让 AI 助手在装 deb 包时自动用上这些经验）\n' "$CD"
fi

# ── 8. PATH 检查 ───────────────────────────────────────────────────────
step "PATH 检查"
case ":$PATH:" in
    *":$BIN_DIR:"*)
        ok "$BIN_DIR 已在 PATH 中" ;;
    *)
        warn "$BIN_DIR 不在当前 PATH 里，命令敲不出来。加进 shell 配置："
        if [ -n "${SHELL:-}" ] && case "$SHELL" in *fish) true ;; *) false ;; esac; then
            printf '      fish_add_path %s\n' "$BIN_DIR"
        else
            printf '      echo '\''export PATH="%s:$PATH"'\'' >> ~/.bashrc && source ~/.bashrc\n' "$BIN_DIR"
        fi
        ;;
esac

# ── 9. 写卸载清单 ───────────────────────────────────────────────────────
if [ $DRY_RUN -eq 0 ]; then
    {
        echo "PREFIX=$PREFIX"
        echo "VERSION=$VERSION"
        echo "INSTALLED=$(date -Iseconds)"
        for f in "${FILES[@]}"; do echo "FILE=$f"; done
    } > /tmp/.debinstall-manifest.$$
    $AS_ROOT install -m 644 /tmp/.debinstall-manifest.$$ "$MANIFEST"
    rm -f /tmp/.debinstall-manifest.$$
    $AS_ROOT install -m 755 "$SRC/uninstall.sh" "$DOC_DIR/uninstall.sh"
    $AS_ROOT install -m 644 "$SRC/README.md" "$DOC_DIR/README.md" 2>/dev/null || true
fi

# ── 10. 自检 ───────────────────────────────────────────────────────────
if [ $DRY_RUN -eq 0 ]; then
    step "自检"
    if "$BIN_DIR/deb-install" --version >/dev/null 2>&1; then
        ok "主程序可执行：$("$BIN_DIR/deb-install" --version)"
    else
        bad "主程序跑不起来，请检查文件权限"
        exit 1
    fi
    if [ $GUI_OK -eq 1 ]; then
        "$GUI_PY" -c "
import ast,sys
ast.parse(open('$BIN_DIR/deb-install-ui').read())
" 2>/dev/null && ok "图形界面脚本语法正常" || warn "图形界面脚本有语法问题"
    fi
fi

echo
printf '%s安装完成%s —— debinstall %s → %s\n' "$CB" "$C0" "$VERSION" "$PREFIX"
echo
echo "  试试看："
echo "    deb-install 某个包.deb            # 只读体检，不动系统"
echo "    deb-install --install 某个包.deb  # 确认后真的安装"
echo "    deb-install -l 某个包.deb         # 装到 ~/.local，不需要 root"
if [ $GUI_OK -eq 1 ]; then
    echo "    双击 .deb 文件                    # 打开图形界面"
fi
echo
[ $DRY_RUN -eq 1 ] && printf '%s（--dry-run：以上都没有真正执行）%s\n\n' "$CY" "$C0"
exit 0
