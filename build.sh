#!/usr/bin/env bash
#
# 打包 debinstall 发布包
#
#   从 ~/.local/bin 同步最新代码 → 替换版本号 → 打成 tar.gz
#
#   ./build.sh                 正常打包
#   ./build.sh --no-sync       只用 packaging/ 里现成的文件，不从系统拉取
#
set -euo pipefail

SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BIN="${BIN:-$HOME/.local/bin}"
DESKTOP="${DESKTOP:-$HOME/.local/share/applications/deb-install.desktop}"
SKILL="${SKILL:-$HOME/.workbuddy/skills/arch-install-deb/SKILL.md}"
DIST="$SELF/dist"

SYNC=1
[ "${1:-}" = "--no-sync" ] && SYNC=0

CB=$'\e[34m'; CG=$'\e[32m'; CY=$'\e[33m'; CD=$'\e[2m'; C0=$'\e[0m'
step() { printf '%s==>%s %s\n' "$CB" "$C0" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$CG" "$C0" "$*"; }
warn() { printf '  %s!%s %s\n' "$CY" "$C0" "$*"; }

# ── 版本号 ──────────────────────────────────────────────────────────────
VERSION=$("$BIN/debinstall" --version 2>/dev/null | awk '{print $NF}')
[ -n "$VERSION" ] || { echo "拿不到版本号，检查 $BIN/debinstall" >&2; exit 1; }
NAME="debinstall-$VERSION"

step "打包 $NAME"

# ── 同步源文件 ──────────────────────────────────────────────────────────
if [ $SYNC -eq 1 ]; then
    step "从系统同步最新文件"
    mkdir -p "$SELF/bin" "$SELF/share/applications" "$SELF/share/doc"
    for f in debinstall deb-install-ui deb-install-open deb-install-askpass deb-install-raw; do
        [ -f "$BIN/$f" ] || { echo "缺 $BIN/$f" >&2; exit 1; }
        install -m 755 "$BIN/$f" "$SELF/bin/$f"
    done
    install -m 644 "$DESKTOP" "$SELF/share/applications/deb-install.desktop"
    install -m 644 "$SKILL"   "$SELF/share/doc/SKILL.md"
    ok "bin/ ×5、desktop、SKILL.md"
else
    warn "--no-sync：使用 packaging/ 里现成的文件"
fi

# ── 保证占位符还在 ──────────────────────────────────────────────────────
# 发布包必须带占位符（由 install.sh 按 PREFIX 替换成真实路径）。
# 但开发机上那份可能早被替换成绝对路径了，同步过来就会丢掉占位符 ——
# 那样打出来的包只能装到本机。这里自动还原，让 build.sh 可重复执行。
_heal_placeholder() {
    local f=$1
    grep -q '@PREFIX_BIN@' "$f" && return 0
    warn "$(basename "$f") 里没有占位符（本机那份已被替换过），自动还原"
    sed -i -E 's|^        "/[^"]*/bin/deb-install",$|        "@PREFIX_BIN@/deb-install",|' "$f"
    if grep -q '@PREFIX_BIN@' "$f"; then
        ok "占位符已还原"
    else
        echo "还原失败：请手工检查 $(basename "$f") 里写死的主程序路径" >&2
        exit 1
    fi
}
_heal_placeholder "$SELF/bin/deb-install-ui"

# ── 组装 ────────────────────────────────────────────────────────────────
step "组装发布目录"
OUT="$DIST/$NAME"
rm -rf "$OUT"
mkdir -p "$OUT/bin" "$OUT/share/applications" "$OUT/share/doc"

for f in debinstall deb-install-ui deb-install-open deb-install-askpass deb-install-raw; do
    install -m 755 "$SELF/bin/$f" "$OUT/bin/$f"
done
install -m 644 "$SELF/share/applications/deb-install.desktop" "$OUT/share/applications/deb-install.desktop"
install -m 644 "$SELF/share/doc/SKILL.md"                     "$OUT/share/doc/SKILL.md"
install -m 755 "$SELF/install.sh"                             "$OUT/install.sh"
install -m 755 "$SELF/uninstall.sh"                           "$OUT/uninstall.sh"
install -m 644 "$SELF/README.md"                              "$OUT/README.md"
if [ -f "$SELF/LICENSE" ]; then
    install -m 644 "$SELF/LICENSE"                            "$OUT/LICENSE"
else
    warn "没有 LICENSE 文件，发布包里不含许可证"
fi

# 版本号落章
sed -i "s|__VERSION__|$VERSION|g" "$OUT/install.sh"
if grep -q '__VERSION__' "$OUT/install.sh"; then
    warn "install.sh 里还有没替换掉的 __VERSION__"
fi
ok "版本号已落章：$VERSION"

# ── 检查占位符 ──────────────────────────────────────────────────────────
if grep -q '@PREFIX_BIN@' "$OUT/bin/deb-install-ui"; then
    ok "deb-install-ui 带 @PREFIX_BIN@ 占位符（安装时按 PREFIX 替换）"
else
    echo "发布包里丢了 @PREFIX_BIN@ 占位符，已中止" >&2
    exit 1
fi

# ── 语法自检 ────────────────────────────────────────────────────────────
step "语法自检"

_syntax_check() {   # 按 shebang 选解释器
    local f=$1 head
    head=$(head -1 "$f")
    case "$head" in
        *python*)
            /usr/bin/python3 -c "import ast,sys;ast.parse(open('$f').read())" \
                || { echo "语法错误（python）：$f" >&2; return 1; } ;;
        *bash*|*sh)
            bash -n "$f" || { echo "语法错误（shell）：$f" >&2; return 1; } ;;
        *)
            warn "认不出解释器，跳过：$f" ;;
    esac
    return 0
}

for f in "$OUT/install.sh" "$OUT/uninstall.sh" "$OUT/bin/debinstall" \
         "$OUT/bin/deb-install-ui" "$OUT/bin/deb-install-open" \
         "$OUT/bin/deb-install-askpass" "$OUT/bin/deb-install-raw"; do
    _syntax_check "$f"
done
ok "全部脚本语法正常"

# ── 打 tar.gz ───────────────────────────────────────────────────────────
step "压缩"
TARBALL="$DIST/$NAME.tar.gz"
tar -czf "$TARBALL" -C "$DIST" "$NAME"
ok "$TARBALL"

# 校验和
( cd "$DIST" && sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256" )
ok "$TARBALL.sha256"

echo
printf '%s%s%s  %s\n' "$CD" "$(du -h "$TARBALL" | cut -f1)" "$C0" "$TARBALL"
printf '%s sha256: %s%s\n\n' "$CD" "$(cut -d' ' -f1 "$TARBALL.sha256")" "$C0"
echo "  测试："
echo "    tar -tzf $TARBALL | head"
echo "    cd /tmp && tar -xzf $TARBALL && ./$NAME/install.sh --dry-run"
