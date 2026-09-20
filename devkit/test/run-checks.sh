#!/usr/bin/env bash
#
# debinstall 回归检查
#
# ⚠️ 安全设计：本脚本【绝不会真的安装任何东西】。
#    - 分析 / 转换（-c）是只读的
#    - 门禁测试用的是 evilprobe（危险命令只在注释里，执行也无害），
#      并且会断言 pacman.log 行数没变 —— 门禁失效能被立刻发现
#    - 本地装/卸往返在【隔离的 HOME】里做，不碰真实 ~/.local
#
# 用法：
#   ./run-checks.sh              跑全部
#   ./run-checks.sh -v           显示每项详情
#
set -uo pipefail

TOOL=${TOOL:-$HOME/.local/bin/debinstall}
UITOOL=${UITOOL:-$HOME/.local/bin/deb-install-ui}
DEBDIR=${DEBDIR:-/tmp/debtest}

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

C_B=$'\e[34m'; C_G=$'\e[32m'; C_R=$'\e[31m'; C_Y=$'\e[33m'; C_D=$'\e[2m'; C_0=$'\e[0m'
PASS=0; FAIL=0; SKIP=0
FAILED_NAMES=()

step() { printf '\n%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
_ok()  { PASS=$((PASS+1)); printf '  %s✓%s %s\n' "$C_G" "$C_0" "$1"; }
_no()  { FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); printf '  %s✗%s %s\n' "$C_R" "$C_0" "$1"; \
         [ -n "${2:-}" ] && printf '        %s\n' "$2"; return 0; }
_sk()  { SKIP=$((SKIP+1)); printf '  %s—%s %s（跳过）\n' "$C_Y" "$C_0" "$1"; }

# check <描述> <命令...>   —— 命令返回 0 视为通过
check() {
    local desc=$1; shift
    if [ $VERBOSE -eq 1 ]; then printf '    %s$ %s%s\n' "$C_D" "$*" "$C_0"; fi
    if "$@" >/dev/null 2>&1; then _ok "$desc"; else _no "$desc"; fi
}

# grep_H <文件> <模式> —— 文件里必须含该模式
grep_H() { grep -qE "$2" "$1"; }
# grep_F <文件> <字面串> —— 文件里必须含该字面串（不看正则）
grep_F() { grep -qF "$2" "$1"; }
# grep_N <文件> <模式> —— 文件里必须【不】含该模式
grep_N() { ! grep -qE "$2" "$1"; }

SELF_DIR="$(dirname "$(readlink -f "$0")")/"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

printf '%sdebinstall 回归检查%s\n' "$C_B" "$C_0"
printf '%s  引擎：%s%s\n' "$C_D" "$TOOL" "$C_0"

# ─────────────────────────────────────────────────────────── 0. 前置
step "0. 环境前置"

if [ -f "$DEBDIR/hello_1.0.0_amd64.deb" ]; then
    _ok "测试包已就绪（$DEBDIR）"
else
    _sk "测试包不存在，先跑 test/make-test-debs.sh"
    echo
    printf '%s请先执行：%s\n  %s\n' "$C_Y" "$C_0" \
        "$(dirname "$(readlink -f "$0")")/make-test-debs.sh"
    exit 2
fi

for c in dpkg-deb bsdtar fakeroot zstd pacman; do
    if command -v "$c" >/dev/null 2>&1; then _ok "命令存在：$c"
    else _no "命令缺失：$c"; fi
done

# pacman 文件数据库 —— 依赖解析的前提（缺了会静默产出空依赖）
if ls /var/lib/pacman/sync/*.files >/dev/null 2>&1; then
    _ok "pacman 文件数据库存在"
else
    _no "pacman 文件数据库缺失（依赖解析会静默失败）" "修：sudo pacman -Fy"
fi

# ─────────────────────────────────────────────────────────── 1. 基本
step "1. 基本接口"

if "$TOOL" --version >"$TMP/v" 2>&1 && grep -q '^debinstall ' "$TMP/v"; then
    _ok "  --version 正常（$(cat "$TMP/v" | tr -d '\n')）"
else
    _no "--version 异常"
fi

if "$TOOL" --help >"$TMP/h" 2>&1 && grep -q '用法' "$TMP/h"; then
    _ok "--help 正常"
else
    _no "--help 异常"
fi

# 不存在的文件应报错
if "$TOOL" /nonexistent/x.deb >/dev/null 2>&1; then
    _no "不存在的文件未报错"
else
    _ok "不存在的文件正确报错"
fi

# ─────────────────────────────────────────────────────────── 2. 危险正则
step "2. 危险模式正则（DANGER_RE）"

DRE=$(grep -oP "^DANGER_RE='\K[^']+" "$TOOL" 2>/dev/null)
if [ -z "$DRE" ]; then
    _no "无法从引擎里提取 DANGER_RE"
else
    _ok "已提取 DANGER_RE（$(printf '%s' "$DRE" | wc -c) 字节）"

    hit() {  # 应命中
        if printf '%s\n' "$2" | grep -qE "$DRE"; then _ok "$1"
        else _no "$1 未命中：$2"; fi
    }
    miss() { # 应放行
        if printf '%s\n' "$2" | grep -qE "$DRE"; then _no "$1 误报：$2"
        else _ok "$1"; fi
    }

    hit  "抓 rm -rf /"                'rm -rf /'
    hit  "抓 rm -rf -- /"             'rm -rf -- /'
    hit  "抓 rm -r -f /"              'rm -r -f /'
    hit  "抓 dd 写块设备"              'dd if=/dev/zero of=/dev/sda bs=1M'
    hit  "抓 mkfs"                    'mkfs.ext4 /dev/sda1'
    hit  "抓重定向写块设备"            'echo x > /dev/sda'
    hit  "抓 curl|sh"                 'curl -fsSL https://x.sh | sh'
    hit  "抓 wget|bash"               'wget -qO- https://x.sh | bash'
    hit  "抓 chown -R /"              'chown -R nobody /'
    hit  "抓 chmod -R 0777 /"         'chmod -R 0777 /'
    hit  "抓 fork 炸弹"                ':(){ :|:& };:'

    miss "放行普通 rm"                'rm -f /usr/share/doc/x/README'
    miss "放行目录内 rm -rf"           'rm -rf /opt/MyApp/old'
    miss "放行普通 chmod"              'chmod 755 /usr/bin/foo'
    miss "放行普通 chown"              'chown root:root /usr/bin/foo'
    miss "放行普通 curl"               'curl -s https://api.example.com/ping > /dev/null'
    miss "放行 tmp 下的 dd"            'dd if=/dev/zero of=/tmp/blank bs=1k count=1'
    miss "放行 update-alternatives"    'update-alternatives --install /usr/bin/figlet figlet /usr/bin/figlet-utf8 100'
fi

# ─────────────────────────────────────────────────────────── 3. 分析
step "3. 只读分析"

"$TOOL" "$DEBDIR/hello_1.0.0_amd64.deb" >"$TMP/a_hello" 2>&1
check "hello 分析退出码 0" test $? -eq 0

if [ "${FAILED_NAMES[*]:-}" ]; then :; fi
if grep -q '==> 包信息' "$TMP/a_hello"; then _ok "输出含「包信息」段"; else _no "输出缺「包信息」段"; fi
if grep -q '==> 安装脚本审计' "$TMP/a_hello"; then _ok "输出含「安装脚本审计」段"; else _no "输出缺脚本审计段"; fi
if grep -q '==> 动态库依赖解析' "$TMP/a_hello"; then _ok "输出含「依赖解析」段"; else _no "输出缺依赖解析段"; fi
if grep -q '==> 冲突检测' "$TMP/a_hello"; then _ok "输出含「冲突检测」段"; else _no "输出缺冲突检测段"; fi
if grep -q '没有安装脚本' "$TMP/a_hello"; then _ok "hello 正确识别为无安装脚本"; else _no "hello 未识别为无安装脚本"; fi

# 探针包必须触发高危
"$TOOL" "$DEBDIR/evilprobe_1.0.0_amd64.deb" >"$TMP/a_probe" 2>&1
if grep -q '含高危操作' "$TMP/a_probe"; then _ok "evilprobe 触发高危检测"; else _no "evilprobe 未触发高危检测"; fi
if grep -q '✗' "$TMP/a_probe"; then _ok "高危结果带 ✗ 标记"; else _no "高危结果缺 ✗ 标记"; fi
if grep -qE '^\s+[0-9]+:#' "$TMP/a_probe"; then _ok "列出命中行的行号"; else _no "未列出命中行行号"; fi
if grep -qE '^\s+postinst [0-9]+ 行' "$TMP/a_probe"; then _ok "打印脚本行数（GUI 抓取用）"; else _no "未打印脚本行数"; fi

# ─────────────────────────────────────────────────────────── 4. 门禁
step "4. 安全门禁（★ 会断言 pacman 未被调用）"

if [ ! -f /var/log/pacman.log ]; then
    _sk "无 /var/log/pacman.log，无法断言"
else
    B=$(wc -l < /var/log/pacman.log)

    # 4.1 非交互 + 高危 + 无 --allow-dangerous → 必须拒绝
    "$TOOL" --install "$DEBDIR/evilprobe_1.0.0_amd64.deb" </dev/null \
        >"$TMP/g1" 2>"$TMP/g1e"; rc=$?
    if [ $rc -ne 0 ]; then _ok "非交互高危包被拒绝（exit $rc）"
    else _no "非交互高危包未被拒绝！"; fi

    if grep -q '非交互模式下拒绝安装' "$TMP/g1e"; then
        _ok "拒绝理由正确（提示 --allow-dangerous）"
    else
        _no "拒绝理由文案不符" "实际 stderr：$(cat "$TMP/g1e")"
    fi

    A1=$(wc -l < /var/log/pacman.log)
    if [ "$B" -eq "$A1" ]; then _ok "pacman 全程未被调用 ✓"
    else _no "pacman 被调用了（$B → $A1 行）—— 门禁失效！"; fi

    if pacman -Q evilprobe >/dev/null 2>&1; then
        _no "evilprobe 竟被装上了"
    else
        _ok "evilprobe 未被安装"
    fi
fi

# ─────────────────────────────────────────────────────────── 5. 转换
step "5. 转换（-c，不安装）"

rm -rf "$TMP/conv"; mkdir -p "$TMP/conv"
( cd "$TMP/conv" && "$TOOL" -c "$DEBDIR/hello_1.0.0_amd64.deb" >"$TMP/c1" 2>&1 )
PKG=$(ls "$TMP/conv"/*.pkg.tar.zst 2>/dev/null | head -1)
if [ -n "$PKG" ]; then
    _ok "生成了 Arch 包：$(basename "$PKG")"
else
    _no "未生成 .pkg.tar.zst"
fi

if [ -n "$PKG" ]; then
    bsdtar -tf "$PKG" >"$TMP/listing" 2>/dev/null
    if grep -qx '.PKGINFO' "$TMP/listing"; then _ok "包内含 .PKGINFO"; else _no "包内缺 .PKGINFO"; fi
    if grep -qx '.MTREE'   "$TMP/listing"; then _ok "包内含 .MTREE"; else _no "包内缺 .MTREE"; fi

    # 条目数自检：源树 vs 包内（防 bsdtar -n 造成的空包）
    n_pkg=$(wc -l < "$TMP/listing")
    n_src=$(dpkg-deb -c "$DEBDIR/hello_1.0.0_amd64.deb" 2>/dev/null | wc -l)
    if [ "$n_pkg" -ge "$n_src" ]; then
        _ok "条目数合理（包内 $n_pkg ≥ 源 $n_src）"
    else
        _no "条目数异常（包内 $n_pkg < 源 $n_src）—— 疑似空包"
    fi

    # 元数据必须排在文件树前面
    if head -1 "$TMP/listing" | grep -qx '.PKGINFO'; then
        _ok ".PKGINFO 是包内第一个条目"
    else
        _no ".PKGINFO 不在首位（pacman 解析可能失败）"
    fi

    bsdtar -xOf "$PKG" .PKGINFO >"$TMP/pkginfo" 2>/dev/null
    if grep -q 'xdata = pkgtype=pkg' "$TMP/pkginfo"; then _ok ".PKGINFO 含 xdata = pkgtype=pkg"
    else _no ".PKGINFO 缺 xdata 行"; fi
    if grep -q '^pkgver = 1\.0\.0-1$' "$TMP/pkginfo"; then _ok "pkgver 格式正确（1.0.0-1）"
    else _no "pkgver 格式异常" "$(grep '^pkgver' "$TMP/pkginfo")"; fi
fi

# ─────────────────────────────────────────────────────────── 6. 元数据映射
step "6. 元数据映射"

# 版本净化：1:2.3.4~rc1-2 → 2.3.4.rc1-2
rm -rf "$TMP/vw"; mkdir -p "$TMP/vw"
( cd "$TMP/vw" && "$TOOL" -c "$DEBDIR"/verweird_*.deb >"$TMP/c2" 2>&1 )
VP=$(ls "$TMP/vw"/*.pkg.tar.zst 2>/dev/null | head -1)
if [ -n "$VP" ]; then
    if bsdtar -xOf "$VP" .PKGINFO 2>/dev/null | grep -q '^pkgver = 2\.3\.4\.rc1-2$'; then
        _ok "版本净化正确（epoch 丢弃、~ → .）"
    else
        _no "版本净化不符" "$(bsdtar -xOf "$VP" .PKGINFO 2>/dev/null | grep '^pkgver')"
    fi
else
    _no "verweird 未生成包"
fi

# 架构映射：all → any
if grep -qE '^\s+Arch 架构\s+any' "$(mktemp)" 2>/dev/null; then :; fi
"$TOOL" "$DEBDIR"/noarchdemo_*.deb >"$TMP/noarch" 2>&1
if grep -qE 'Arch 架构\s+any' "$TMP/noarch"; then _ok "架构映射 all → any"
else _no "架构映射 all → any 失败"; fi
if grep -q '架构匹配本机' "$TMP/noarch"; then _ok "any 判定为架构匹配"
else _no "any 未判定为架构匹配"; fi

# 依赖映射（BUILTIN_MAP，只出现在转包产物的 .PKGINFO 里）
rm -rf "$TMP/dep"; mkdir -p "$TMP/dep"
( cd "$TMP/dep" && "$TOOL" -c "$DEBDIR/printfake_2.1.0_amd64.deb" >"$TMP/c3" 2>&1 )
DP=$(ls "$TMP/dep"/*.pkg.tar.zst 2>/dev/null | head -1)
if [ -n "$DP" ]; then
    bsdtar -xOf "$DP" .PKGINFO 2>/dev/null | grep '^depend = ' | sed 's/^depend = //' | sort > "$TMP/deps"
    map_check() {   # $1=期望的 Arch 包名
        if grep -qx "$1" "$TMP/deps"; then _ok "依赖映射 $2 → $1"
        else _no "依赖映射缺 $1（来自 $2）"; fi
    }
    map_check glibc      "libc6 / ELF libc.so.6"
    map_check nss        "libnss3"
    map_check gtk3       "libgtk-3-0"
    map_check zlib       "zlib1g"
    map_check ttf-dejavu "fonts-dejavu-core"
    map_check xdg-utils  "xdg-utils"

    # 包自带的 .so 不应被当成外部依赖
    if grep -q 'libprintfake' "$TMP/deps"; then
        _no "包自带的 soname 被误判为外部依赖"
    else
        _ok "包自带 .so 正确排除"
    fi
else
    _no "printfake 未生成包"
fi

# ─────────────────────────────────────────────────────────── 7. GUI 协议
step "7. GUI 文本协议（改动引擎文案后最容易破）"

if [ ! -f "$UITOOL" ]; then
    _sk "GUI 脚本不存在：$UITOOL"
else
    if /usr/bin/python3 -c "import ast;ast.parse(open('$UITOOL').read())" 2>/dev/null; then
        _ok "GUI 脚本语法正常"
    else
        _no "GUI 脚本语法错误"
    fi

    # 字面串：引擎输出里必须都在（GUI 的"详细输出"日志与安全门禁依赖它们）
    proto_check() {   # $1=字面串  $2=出现在哪个测试包的分析里
        local f
        case "$2" in
            hello) f="$TMP/a_hello" ;;
            probe) f="$TMP/a_probe" ;;
            *)     f="$TMP/a_hello" ;;
        esac
        if grep -qF "$1" "$f"; then _ok "协议串存在：$1"
        else _no "协议串缺失：$1" "GUI 详细输出/门禁会缺信息（改文案时漏了？）"; fi
    }
    proto_check '没有安装脚本'         hello
    proto_check '所有动态库已满足'      hello
    proto_check '没有 desktop 遮蔽冲突' hello
    proto_check '高危'                probe

    # GUI 侧的正则/子串也必须和引擎一致
    if grep -q '包名' "$UITOOL" && grep -qE '^\s*包名\s' "$TMP/a_hello"; then
        _ok "「包名」两边一致"
    else
        _no "「包名」格式两边不一致"
    fi
    # 极简契约：标识行靠 包名/版本，安全门禁靠「高危」
    if grep -q '高危' "$UITOOL" && grep -q '版本' "$UITOOL"; then
        _ok "GUI 极简契约在位（标识 包名/版本 + 高危门禁）"
    else
        _no "GUI 极简契约缺失" "标识行或高危门禁被改？"
    fi

    # shebang 必须是系统 python（gi 装在它下面）
    if head -1 "$UITOOL" | grep -q '^#!/usr/bin/python3$'; then
        _ok "GUI shebang 是 /usr/bin/python3"
    else
        _no "GUI shebang 不是 /usr/bin/python3" "改成 env python3 可能命中无 gi 的解释器"
    fi
fi

# ─────────────────────────────────────────────────────────── 7b. AppImage
step "7b. AppImage 分支（GUI 层只读检查 + 移入 ~/Applications）"

if [ ! -f "$UITOOL" ]; then
    _sk "GUI 脚本不存在：$UITOOL"
else
    for sym in is_appimage _analyze_appimage _appimage_probe _appimage_scan_done \
               _install_appimage _manifest_path _desktop_exec _appimage_desk_link; do
        check "GUI 有 $sym()" grep_H "$UITOOL" "def $sym"
    done
    check "GUI 里 AppImage 走 ~/Applications" grep_F "$UITOOL" '"Applications"'

    # 安全底线：外来 AppImage 一次都不能被执行。跑一次就等于让对方在你机器上
    # 任意执行，包路径只能作为【参数】交给 file / 7z，不能当 argv[0]。
    if grep -qE 'Popen\((path|dst)|_cmd\(\[(path|dst)|run\(\[(path|dst)' "$UITOOL"; then
        _no "GUI 可能把 AppImage 当命令执行" "只读检查是硬要求，别改"
    else
        _ok "GUI 不会执行 AppImage 本体"
    fi

    # 图标必须在【移动后】的 dst 上抽：原路径此时已经不存在了
    if grep -qF 'f"-o{tmp}", dst' "$UITOOL"; then
        _ok "图标从移动后的 dst 抽取"
    else
        _no "图标抽取用的还是移动前的 path" "移走文件后原路径为空，图标会静默丢失"
    fi

    # AppImage 分支不碰特权：既不 sudo，也不调引擎
    _aisec=$(awk '/def _install_appimage/,/def _appimage_desk_link/' "$UITOOL")
    if printf '%s' "$_aisec" | grep -qE 'sudo|run_root|--install|pacman'; then
        _no "AppImage 安装里出现了特权/引擎调用" "这条路径设计成完全不需要 root"
    else
        _ok "AppImage 安装全程不用 root"
    fi

    # Exec 里的文件名必须转义，否则恶意文件名能把 .desktop 撑出去
    check "_desktop_exec 转义 \" \$ 和反引号" grep_F "$UITOOL" '.replace("$", "\\$")'

    # slug 会当文件名用，必须证明它过滤过
    check "slugify 只留安全字符" grep_F "$UITOOL" '[^0-9A-Za-z_.+-]+'

    # 纯中文的 Name 会被 slugify 掏成通用的 "appimage"，两个应用会抢
    # 同一个 <slug>.desktop —— 必须留一条退回文件名的路
    check "slug 退化成通用值时用文件名兜底" grep_F "$UITOOL" 'if s != "appimage"'

    # ── 桌面入口与关联 ──
    DESK="${DESK:-$HOME/.local/share/applications/deb-install.desktop}"
    if [ -f "$DESK" ]; then
        if grep -q 'application/vnd.appimage' "$DESK" \
           && grep -q 'application/vnd.debian.binary-package' "$DESK"; then
            _ok "桌面入口同时声明 .deb 与 .AppImage"
        else
            _no "桌面入口缺 MIME 声明" "双击 .AppImage 找不到本工具"
        fi
        if command -v desktop-file-validate >/dev/null 2>&1; then
            check "桌面入口通过 desktop-file-validate" \
                desktop-file-validate "$DESK"
        fi
        if command -v xdg-mime >/dev/null 2>&1; then
            CUR=$(xdg-mime query default application/vnd.appimage 2>/dev/null || true)
            if [ "$CUR" = "deb-install.desktop" ]; then
                _ok "本机 .AppImage 默认打开方式已指向 deb-install"
            else
                _sk ".AppImage 关联未生效（当前 ${CUR:-无}）—— 跑 install.sh 会补上"
            fi
        fi
    else
        _sk "本机没部署桌面入口：$DESK"
    fi

    PKG="${PKGDIR:-$HOME/deb-tools/packaging}"
    if [ -f "$PKG/install.sh" ]; then
        check "install.sh 注册 .AppImage 关联" grep_F "$PKG/install.sh" 'application/vnd.appimage'
        check "uninstall.sh 解除 .AppImage 关联" grep_F "$PKG/uninstall.sh" 'application/vnd.appimage'
        check "install.sh 的关联循环覆盖两种 MIME" grep_F "$PKG/install.sh" 'for mime in'
    else
        _sk "找不到打包脚本目录 $PKG"
    fi

    # ── 实测：真拿一个 AppImage 过一遍扫描（纯只读，不开窗口）──
    PROBE="${SELF_DIR}probe-appimage.py"
    SAMPLE=${AISAMPLE:-$(find "$HOME/Downloads" -maxdepth 1 -name '*.AppImage' -print -quit 2>/dev/null)}
    if [ ! -f "$PROBE" ]; then
        _sk "缺少 probe-appimage.py"
    elif ! /usr/bin/python3 -c 'import gi' 2>/dev/null; then
        _sk "系统 python 没有 gi，跳过 AppImage 实测"
    elif [ -z "${SAMPLE:-}" ] || [ ! -f "$SAMPLE" ]; then
        _sk "没有可用的 .AppImage 样例（放一个到 ~/Downloads 或设 AISAMPLE）"
    else
        /usr/bin/python3 "$PROBE" "$UITOOL" "$SAMPLE" "$TMP/ai.env" >"$TMP/ai.log" 2>&1
        if [ -s "$TMP/ai.env" ]; then
            . "$TMP/ai.env"          # 值由 python 单引号包裹并转义
            if [ "${ai_rc:-1}" = "0" ]; then _ok "实测样例扫描通过：$(basename "$SAMPLE")"
            else _no "实测样例扫描失败" "$(tail -3 "$TMP/ai.log")"; fi
            [ -n "${ai_name:-}" ] && _ok "解析出应用名：$ai_name" || _no "解析不出应用名"
            case "${ai_icon:-}" in
                usr/share/icons/hicolor/*) _ok "图标指向 hicolor 真身（不是根符号链接）" ;;
                "") _sk "样例没有图标" ;;
                *) _no "图标路径不对" "$ai_icon" ;;
            esac
            case "${ai_desktop:-}" in
                usr/share/applications/*) _ok ".desktop 取 usr/share 下的真身" ;;
                "") _sk "样例没有 .desktop" ;;
                *) _no ".desktop 路径不对" "$ai_desktop" ;;
            esac
            case "${ai_slug:-}" in
                ""|*/*|*..*|*.sh) _no "slug 不能安全地当文件名用" "$ai_slug" ;;
                *) _ok "slug 可用于文件名：$ai_slug" ;;
            esac
        else
            _no "AppImage 实测没产出结果" "$(tail -5 "$TMP/ai.log")"
        fi

        # 反例：shell 脚本冒充 .AppImage 必须被拒（type-1 或干脆不是包）
        printf '#!/bin/sh\necho fake\n' > "$TMP/fake.AppImage"
        if /usr/bin/python3 "$PROBE" "$UITOOL" "$TMP/fake.AppImage" "$TMP/ai2.env" \
             >/dev/null 2>&1 && [ -s "$TMP/ai2.env" ]; then
            . "$TMP/ai2.env"
            if [ "${ai_rc:-0}" != "0" ]; then
                _ok "非 ELF 的假 AppImage 被拒"
            else
                _no "假 AppImage 居然通过了扫描" "门禁形同虚设"
            fi
        else
            _no "反例探测没跑起来"
        fi
    fi
fi

# ─────────────────────────────────────────────────────────── 8. 本地装/卸
step "8. 本地安装往返（隔离 HOME，不碰真实环境）"

ISO="$TMP/iso"; mkdir -p "$ISO"
if HOME="$ISO" DEBINSTALL_LOCAL_ROOT="$ISO/.local/debinst" \
   "$TOOL" -l "$DEBDIR/hello_1.0.0_amd64.deb" >"$TMP/l1" 2>&1; then
    _ok "本地安装成功"
else
    _no "本地安装失败" "$(tail -3 "$TMP/l1")"
fi

if [ -d "$ISO/.local/debinst/hello" ]; then _ok "建立本地安装根"
else _no "未建立本地安装根"; fi

if [ -x "$ISO/.local/bin/hello" ] || [ -L "$ISO/.local/bin/hello" ]; then
    _ok "可执行文件已软链到 ~/.local/bin"
else
    _no "未建立 ~/.local/bin 软链"
fi

if HOME="$ISO" DEBINSTALL_LOCAL_ROOT="$ISO/.local/debinst" \
   "$TOOL" -L >"$TMP/l2" 2>&1 && grep -q 'hello' "$TMP/l2"; then
    _ok "-L 列出本地包"
else
    _no "-L 未列出本地包"
fi

if HOME="$ISO" DEBINSTALL_LOCAL_ROOT="$ISO/.local/debinst" \
   "$TOOL" -R hello >"$TMP/l3" 2>&1; then
    _ok "本地卸载成功"
else
    _no "本地卸载失败" "$(tail -3 "$TMP/l3")"
fi

if [ -e "$ISO/.local/debinst/hello" ]; then _no "卸载后安装根仍在"
else _ok "卸载后安装根已清除"; fi
if [ -e "$ISO/.local/bin/hello" ]; then _no "卸载后软链残留"
else _ok "卸载后软链已清除"; fi

# ─────────────────────────────────────────────────────────── 9. alternatives
step "9. update-alternatives 模拟"

# shim 是否可从引擎里解出且语法正确
SHIM=$(mktemp)
if grep -oP '^_ALT_SHIM_B64="\K[^"]+' "$TOOL" 2>/dev/null | base64 -d > "$SHIM" 2>/dev/null; then
    if [ -s "$SHIM" ]; then
        _ok "内嵌 shim 可解码（$(wc -l < "$SHIM") 行）"
        if sh -n "$SHIM" 2>/dev/null; then _ok "shim 语法正确"
        else _no "shim 语法错误"; fi
        if grep -q -- '--install' "$SHIM"; then _ok "shim 实现 --install"
        else _no "shim 缺 --install"; fi
        if grep -q -- '--remove' "$SHIM"; then _ok "shim 实现 --remove"
        else _no "shim 缺 --remove"; fi
        # 陷阱检测：只扫“代码”，先剥掉注释再匹配。
        # 注意 shim 自己的说明注释里就会写出 `grep -vF ... > tmp && mv` 这个模式，
        # 若不剥注释会误判成陷阱写法（此断言曾因此假失败）。
        if sed 's/#.*//' "$SHIM" | grep -qE 'grep -vF[^;]*&&[^|]*mv'; then
            _no "shim 里仍有 grep|mv && 的陷阱写法" "全部行被过滤时 mv 不执行，台账会残留"
        else
            _ok "shim 未使用 grep|mv && 陷阱写法"
        fi
    else
        _no "内嵌 shim 解码为空"
    fi
else
    _no "无法解码内嵌 shim"
fi
rm -f "$SHIM"

# 本地模式对 altgen 的 alternatives 模拟
ISO2="$TMP/iso2"; mkdir -p "$ISO2"
HOME="$ISO2" DEBINSTALL_LOCAL_ROOT="$ISO2/.local/debinst" \
    "$TOOL" -l "$DEBDIR/altgen_1.0.0_amd64.deb" >"$TMP/alt" 2>&1
if grep -q '命令别名' "$TMP/alt"; then
    _ok "本地模式模拟出命令别名"
    if [ -e "$ISO2/.local/bin/altgen" ]; then _ok "别名链接已建立"
    else _no "别名链接未建立"; fi
else
    # 本地模式不跑 postinst，靠解析源码补 —— 拿不到就是模拟失效
    if [ -e "$ISO2/.local/bin/altgen" ]; then
        _ok "别名链接已建立"
    else
        _no "alternatives 模拟未生效" "$(grep -i '别名\|alt' "$TMP/alt" | head -3)"
    fi
fi

# ─────────────────────────────────────────────────────────── 10. 打包完整性
step "10. 分发打包完整性"

PKGDIR=${PKGDIR:-$HOME/deb-tools/packaging}
if [ -d "$PKGDIR" ]; then
    if grep -q 'PREFIX_BIN@' "$PKGDIR/bin/deb-install-ui" 2>/dev/null; then
        _ok "打包源里保留 @PREFIX_BIN@ 占位符"
    else
        _no "打包源里丢了占位符（本机副本被 sed 替换过？）" "跑 build.sh 会自动还原"
    fi
    if grep -q '_heal_placeholder' "$PKGDIR/build.sh" 2>/dev/null; then
        _ok "build.sh 有占位符自愈逻辑"
    else
        _no "build.sh 缺 _heal_placeholder"
    fi
    # GUI 的占位符校验标记必须是拼开的
    if grep -qE '"_PH = "@PREFIX_" \+ "BIN@"|_PH = "@PREFIX_" \+ "BIN@"' \
            "$PKGDIR/bin/deb-install-ui" 2>/dev/null; then
        _ok "GUI 的占位符校验标记是拼开写的"
    else
        _no "GUI 的占位符校验标记被写成字面量" "sed 会把它一起替换，导致装好后跳过正确路径"
    fi
else
    _sk "未找到打包目录：$PKGDIR"
fi

# ─────────────────────────────────────────────────────────── 11. 补库与兼容启动器
step "11. Debian 补库与兼容启动器"

# 这一节是「网易邮箱大师」那次踩坑的防复发检查。三层坑：
#   1) launch.sh 里的 lsb_release 发行版检查 → 要绕过，不能傻 exec 那个 sh
#   2) libnss_wrapper.so / libsasl2.so.2 等 Arch 仓库没有的库 → 要从 Debian 补
#   3) 自带 Qt5 的 GLX 在 Mesa 上段错误 → 应用专属，靠 .env 注入
# 前两层的实现都在下面这些点里，逐个断言。

grep_H "$TOOL" '^debian_pkg_for_soname\(\)' && _ok "实现了 soname → Debian 包名查询" \
    || _no "缺 debian_pkg_for_soname"
grep_H "$TOOL" '^debian_deb_url\(\)' && _ok "实现了 Debian 包名 → .deb 直链" \
    || _no "缺 debian_deb_url"
grep_H "$TOOL" '^setup_compat_libs\(\)' && _ok "实现了补库主流程" || _no "缺 setup_compat_libs"
grep_H "$TOOL" '^missing_sonames\(\)' && _ok "实现了缺失 soname 枚举" || _no "缺 missing_sonames"
grep_H "$TOOL" '^make_compat_wrapper\(\)' && _ok "实现了兼容启动器生成" || _no "缺 make_compat_wrapper"

# 直链拼接不能把发行版名重复：镜像 URL 形如 http://host/debian/pool/...
# 早先用「去掉 http://host/ 前缀」的写法，拼出来是 .../debian/debian/pool/。
# 这里断言用的是直接抓 pool/... 的写法。
if grep -qE "grep -oE 'pool/\[" "$TOOL" && ! grep -q 'https\?://\[^/\]+/' "$TOOL"; then
    _ok "直链拼接不重复 /debian/"
else
    _no "直链拼接可能重复 /debian/（检查 debian_deb_url）"
fi

# 裸 launch.sh 会被直接 exec，必须认出同目录的真身二进制
grep_H "$TOOL" 'launch\.sh\|start\.sh\|run\.sh' && _ok "识别 launch.sh 这类包装脚本" \
    || _no "没处理 launch.sh 包装脚本（会被发行版检查拦下）"
grep_H "$TOOL" 'X-DebInstall-Wrapper=1' && _ok "用标记区分自己生成的桌面入口" \
    || _no "缺 X-DebInstall-Wrapper 标记"
grep_H "$TOOL" 'debinstall 兼容启动器' && _ok "启动器带归属标记（便于安全覆盖）" \
    || _no "启动器缺归属标记"

# 应用专属修复落在 .env，重新生成启动器时不能被冲掉
grep_H "$TOOL" 'COMPAT_ENV_DIR' && _ok "支持应用专属修复文件（.env）" || _no "缺 COMPAT_ENV_DIR"
grep_H "$TOOL" '\[ ! -e "\$envf" \]' && _ok "已有 .env 不会被覆盖" \
    || _no ".env 会被覆盖（用户修好的东西会丢）"

# 桌面快捷方式：内容相同就不动，不同先备份 —— 不能无条件 cp -f
grep_H "$TOOL" 'cmp -s "\$src" "\$dest"' && _ok "桌面快捷方式内容相同则跳过" \
    || _no "桌面快捷方式仍是无条件覆盖"
grep_H "$TOOL" '\$dest\.bak-\$\(date' && _ok "覆盖前先备份桌面快捷方式" \
    || _no "覆盖桌面快捷方式不带备份"

# 遮蔽提示要分方向，不能无脑建议删用户级那份
grep_H "$TOOL" '^desktop_exec_ok\(\)' && _ok "按 Exec 可用性判断遮蔽方向" \
    || _no "遮蔽冲突仍是无脑建议 mv 走用户级（会删掉修好的那份）"
grep_H "$TOOL" '不要 mv 走' && _ok "两种情况分别给出正确建议" || _no "遮蔽提示缺反向分支"
# 用户级那份若带 wrapper 标记，要说清「这是补库入口，删了会起不来」，
# 而不是套用「像是你自定义过的」那套话术
grep_H "$TOOL" '本工具生成的兼容启动器入口' && _ok "识别自家的 wrapper 入口并提示保留" \
    || _no "没把自家 wrapper 入口与用户自定义区分开"

# 参数与收尾接线
grep_H "$TOOL" '[-]{2}no-compat' && _ok "提供 --no-compat 开关" || _no "缺 --no-compat"
grep_H "$TOOL" 'setup_compat_libs "\$croot"' && _ok "安装流程里接了补库" \
    || _no "do_install 没调用 setup_compat_libs"
# 第二次安装时库已在 COMPAT_DIR，不需要下载 —— 但启动器仍必须保证在位。
# 判断「要不要生成启动器」必须用不含 COMPAT_DIR 的那次扫描，否则会漏接线，
# 表现为「第一次装好好的，重装一次图标就失灵」。
grep_H "$TOOL" 'mapfile -t bare < <\(missing_sonames "\$root"\)' \
    && _ok "按「裸系统是否缺库」判断要不要生成启动器" \
    || _no "只按「这轮要不要下载」判断，重装会漏生成启动器"
if awk '/\[ \$needs_wrapper -eq 1 \] && make_compat_wrapper/{a=NR} END{exit !a}' "$TOOL"; then
    _ok "启动器生成放在最后统一处理"
else
    _no "启动器生成没统一到末尾，「无需下载」路径会漏掉"
fi
# 补库要复用 build_arch_pkg 解好的树，别再解一次（大包解一次几百 MB）
if awk '/local croot="\$WORK\/root"/{a=NR} END{exit !a}' "$TOOL"; then
    _ok "补库复用已解开的树（不重复解包）"
else
    _no "补库又解了一次 .deb（大包代价高）"
fi
# 补库必须在桌面快捷方式之前（否则桌面那份拿不到 wrapper 版本）
if awk '/setup_compat_libs "\$croot"/{a=NR} /make_desktop_shortcut$/{b=NR} END{exit !(a && b && a<b)}' "$TOOL"; then
    _ok "补库在桌面快捷方式之前执行"
else
    _no "执行顺序不对：桌面快捷方式先于补库，会拿到未注入库的 Exec"
fi

# 目录权限规范化（消除 pacman 警告 + /opt 下应用目录组可写）
grep_H "$TOOL" 'chmod go-w' && _ok "包装包时规范化目录权限" || _no "缺目录权限规范化"
grep_H "$TOOL" 'DEBINSTALL_KEEP_DIR_PERM' && _ok "目录权限规范化可关闭" || _no "缺权限规范的逃生开关"

# 行为测试：真跑一次 soname 查询与直链解析（需要网络，失败只跳过）
extract_funcs() {   # $1 = 输出文件；$2.. = 函数名
    local out=$1; shift
    : > "$out"
    local f
    for f in "$@"; do
        awk -v fn="^${f}[(][)]" '$0 ~ fn,/^}/' "$TOOL" >> "$out"
        printf '\n' >> "$out"
    done
}
if command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; then
    extract_funcs "$TMP/fn.sh" http_get debian_pkg_for_soname debian_deb_url
    {
        printf 'VERSION=test\n'
        printf 'have(){ command -v "$1" >/dev/null 2>&1; }\n'
        printf '. %s\n' "$TMP/fn.sh"
        printf 'r=$(debian_pkg_for_soname libnss_wrapper.so) || exit 1\n'
        printf '[ -n "$r" ] || exit 1\n'
        printf 'set -- $r\n'
        printf 'u=$(debian_deb_url "$2" "$1") || exit 1\n'
        printf 'case "$u" in https://deb.debian.org/debian/pool/*.deb) : ;; *) exit 1 ;; esac\n'
        printf 'printf "%%s\\n" "$u"\n'
    } > "$TMP/net.sh"
    if out=$(timeout 60 bash "$TMP/net.sh" 2>/dev/null); then
        _ok "实测：libnss_wrapper.so → Debian 包 → 直链可解析"
        [ $VERBOSE -eq 1 ] && printf '        %s%s%s\n' "$C_D" "$out" "$C_0"
    else
        _sk "联网行为测试未通过（网络受限？不影响离线检查）"
    fi
else
    _sk "没有 curl/wget，跳过联网行为测试"
fi

# ─────────────────────────────────────────────────────────── 汇总
echo
printf '%s────────────────────────────────────────%s\n' "$C_D" "$C_0"
printf '  通过 %s%d%s   失败 %s%d%s   跳过 %s%d%s\n' \
    "$C_G" "$PASS" "$C_0" "$([ $FAIL -gt 0 ] && printf %s "$C_R" || printf %s "$C_G")" \
    "$FAIL" "$C_0" "$C_Y" "$SKIP" "$C_0"

if [ $FAIL -gt 0 ]; then
    echo
    printf '%s失败项：%s\n' "$C_R" "$C_0"
    for n in "${FAILED_NAMES[@]}"; do printf '  · %s\n' "$n"; done
    echo
    exit 1
fi

echo
printf '%s全部通过。%s\n' "$C_G" "$C_0"
exit 0
