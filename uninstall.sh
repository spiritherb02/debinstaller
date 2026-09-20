#!/usr/bin/env bash
#
# debinstall —— 卸载脚本
#
# 会按安装时记下的清单逐个删除文件，并解除 .deb 文件关联。
# 它不会碰你用它安装过的任何 .deb 软件包——那些是 pacman 管的，另用
# `pacman -R` 或 `deb-install -R` 处理。
#
#   ./uninstall.sh                正常卸载
#   ./uninstall.sh --keep-skill   保留 WorkBuddy 技能文档
#   ./uninstall.sh --dry-run      只看会删什么，不动手
#
set -euo pipefail

SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PREFIX=$(cd "$SELF/../.." && pwd)          # …/<prefix>/share/debinstall → <prefix>
MANIFEST="$SELF/manifest.txt"
SKILL_DIR="$HOME/.workbuddy/skills/arch-install-deb"

KEEP_SKILL=0
DRY_RUN=0
FORCE=0

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    CR=$'\e[31m'; CG=$'\e[32m'; CY=$'\e[33m'; CB=$'\e[34m'; CD=$'\e[2m'; C0=$'\e[0m'
else
    CR=; CG=; CY=; CB=; CD=; C0=
fi
step() { printf '%s==>%s %s\n' "$CB" "$C0" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$CG" "$C0" "$*"; }
warn() { printf '  %s!%s %s\n' "$CY" "$C0" "$*"; }
die()  { printf '%s==>%s %s\n' "$CR" "$C0" "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --keep-skill) KEEP_SKILL=1 ;;
        --dry-run)    DRY_RUN=1 ;;
        --force)      FORCE=1 ;;
        -h|--help)    sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)            die "未知参数：$1" ;;
    esac
    shift
done

printf '\n%sdebinstall 卸载%s —— 前缀 %s%s%s\n\n' "$CB" "$C0" "$CD" "$PREFIX" "$C0"

# ── 定位清单 ────────────────────────────────────────────────────────────
if [ ! -f "$MANIFEST" ]; then
    warn "找不到安装清单：$MANIFEST"
    if [ $FORCE -eq 0 ]; then
        echo "      没有清单就无法确定当初装了哪些文件。"
        echo "      如果你确定要卸载，可以看这个目录里有什么，手动删掉："
        echo "        $PREFIX/bin/debinstall 等            （在 $PREFIX/bin）"
        echo "        $PREFIX/share/applications/deb-install.desktop"
        echo "        $SELF"
        echo "      或者加 --force 让我按默认文件名推测着删。"
        exit 1
    fi
    FILES=()
else
    # 读出文件列表（FILE= 行）
    FILES=()
    while IFS= read -r line; do
        case "$line" in
            FILE=*) FILES+=("${line#FILE=}") ;;
        esac
    done < "$MANIFEST"
fi

if [ $FORCE -eq 1 ] && [ ${#FILES[@]} -eq 0 ]; then
    warn "--force 模式：按默认布局推测要删的文件"
    for f in debinstall deb-install deb-install-ui deb-install-open \
             deb-install-askpass deb-install-raw; do
        FILES+=("$PREFIX/bin/$f")
    done
    FILES+=("$PREFIX/share/applications/deb-install.desktop")
fi

# 技能文档是否真的由本次安装写入？只有清单里记着才动它。
# 否则用 ./install.sh --no-skill 装的、或者本来就是别人装的，
# 一卸载就被顺手删掉，属于误伤。
SKILL_INSTALLED=0
for f in "${FILES[@]}"; do
    if [ "$f" = "$SKILL_DIR/SKILL.md" ]; then SKILL_INSTALLED=1; fi
done

# 我们装的 desktop 文件是否处在 XDG 搜索路径里？只有这种安装才有资格
# 去清 .deb 关联。装到 /tmp/xxx 或者 /opt 这种非标准位置时，
# xdg-mime 指向的根本不是我们，清了就是替别人做决定。
_app_dir_is_authoritative() {
    local dir="$PREFIX/share/applications" d
    [ "$dir" = "${XDG_DATA_HOME:-$HOME/.local/share}/applications" ] && return 0
    for d in ${XDG_DATA_DIRS:-/usr/local/share:/usr/share}; do
        [ "$dir" = "$d/applications" ] && return 0
    done
    return 1
}

# ── 目视确认 ────────────────────────────────────────────────────────────
step "将删除以下文件"
NEED_ROOT=0
for f in "${FILES[@]}"; do
    if [ -e "$f" ] || [ -L "$f" ]; then
        printf '      %s\n' "$f"
        [ -w "$f" ] || NEED_ROOT=1
    else
        printf '      %s %s（不存在，跳过）%s\n' "$CD" "$f" "$C0"
    fi
done

AS_ROOT=""
if [ $NEED_ROOT -eq 1 ]; then
    AS_ROOT="sudo"
    warn "部分文件需要管理员权限，会用到 sudo"
fi

# ── 执行删除 ────────────────────────────────────────────────────────────
step "删除文件"
for f in "${FILES[@]}"; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    if [ $DRY_RUN -eq 0 ]; then
        $AS_ROOT rm -f "$f" 2>/dev/null || { warn "删不掉：$f（跳过）"; continue; }
        printf '      %s已删除%s %s\n' "$CD" "$C0" "$f"
    else
        printf '      %s将删除%s %s\n' "$CD" "$C0" "$f"
    fi
done

# ── 解除文件关联 ────────────────────────────────────────────────────────
if command -v xdg-mime >/dev/null 2>&1; then
    step "检查 .deb / .AppImage 文件关联"
    for mime in application/vnd.debian.binary-package application/vnd.appimage; do
        case "$mime" in
            *deb*) label=".deb";      re='application\/vnd\.debian\.binary-package' ;;
            *)     label=".AppImage"; re='application\/vnd\.appimage' ;;
        esac
        CUR=$(xdg-mime query default "$mime" 2>/dev/null || true)
        if [ "$CUR" != "deb-install.desktop" ]; then
            ok "$label 关联未指向 deb-install，无需处理"
        elif ! _app_dir_is_authoritative; then
            warn "$label 关联归别的安装位置管（$PREFIX/share/applications 不在 XDG 搜索路径里）"
            printf '      不动它。要去掉的话在对应安装位置上跑它的 uninstall.sh\n'
        else
            if [ $DRY_RUN -eq 0 ]; then
                # xdg-mime 没有 unset 子命令，直接改写 mimeapps.list
                MF="$HOME/.config/mimeapps.list"
                if [ -f "$MF" ] && grep -qF "$mime" "$MF"; then
                    awk -v re="$re" '
                        /^\[Default Applications\]/ { print; ind=1; next }
                        /^\[/ { ind=0 }
                        ind && $0 ~ re { next }
                        { print }
                    ' "$MF" > "$MF.new" && mv "$MF.new" "$MF"
                fi
            fi
            ok "已清除 $label 关联（原来的默认程序如 Ark 会重新接管）"
        fi
    done
    if [ $DRY_RUN -eq 0 ] && command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$PREFIX/share/applications" >/dev/null 2>&1 || true
    fi
fi

# ── 技能文档 ────────────────────────────────────────────────────────────
if [ $KEEP_SKILL -eq 1 ]; then
    warn "按 --keep-skill 保留技能文档"
elif [ "$SKILL_INSTALLED" -eq 0 ]; then
    if [ -f "$SKILL_DIR/SKILL.md" ]; then
        warn "技能文档不在本次安装清单里，保留不动（要删的话自己删 $SKILL_DIR）"
    fi
else
    step "移除 WorkBuddy 技能文档"
    if [ $DRY_RUN -eq 0 ]; then
        rm -f "$SKILL_DIR/SKILL.md"
        rmdir "$SKILL_DIR" 2>/dev/null && rmdir "$(dirname "$SKILL_DIR")" 2>/dev/null || true
    fi
    ok "$SKILL_DIR/SKILL.md"
fi

# ── 清理自身目录 ────────────────────────────────────────────────────────
step "清理安装目录"
APP_DIR="$PREFIX/share/applications"
if [ $DRY_RUN -eq 0 ]; then
    $AS_ROOT rm -f "$MANIFEST" 2>/dev/null || true
    $AS_ROOT rm -f "$SELF/README.md" 2>/dev/null || true
    # 桌面数据库生成的缓存：目录里已经没有别的 desktop 文件才删
    if [ -f "$APP_DIR/mimeinfo.cache" ]; then
        if [ -z "$(find "$APP_DIR" -maxdepth 1 -name '*.desktop' -print -quit 2>/dev/null)" ]; then
            $AS_ROOT rm -f "$APP_DIR/mimeinfo.cache" 2>/dev/null || true
        fi
    fi
    $AS_ROOT rmdir "$APP_DIR" 2>/dev/null || true
    $AS_ROOT rmdir "$PREFIX/bin" 2>/dev/null || true
    $AS_ROOT rmdir "$PREFIX/share" 2>/dev/null || true
    # 最后删自己：Linux 下已打开的脚本删掉仍能继续跑完
    $AS_ROOT rm -f "$SELF/uninstall.sh" 2>/dev/null || true
    rmdir "$SELF" 2>/dev/null || $AS_ROOT rmdir "$SELF" 2>/dev/null || true
    printf '      %s已清理%s %s\n' "$CD" "$C0" "$PREFIX/share/debinstall"
else
    printf '      %s将清理%s %s\n' "$CD" "$C0" "$PREFIX/share/debinstall"
fi

echo
if [ $DRY_RUN -eq 1 ]; then
    printf '%s（--dry-run：以上都没有真正删除）%s\n\n' "$CY" "$C0"
else
    printf '%s卸载完成%s\n' "$CB" "$C0"
    echo "  注意：你用 debinstall 装过的软件包仍在系统里（pacman 记录的），"
    echo "        需要的话自己卸：pacman -R <包名>   或   deb-install -R <包名>"
    echo
fi
