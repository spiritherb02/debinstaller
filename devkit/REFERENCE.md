# debinstall 速查参考

配套 `DESIGN.md`（逻辑说明）使用。本文只列**事实**：选项、签名、格式、变量。

---

## 1. 命令行接口

### 1.1 `debinstall`（主引擎）

```
debinstall [选项] <文件.deb>
```

#### 模式（互斥）

| 选项 | MODE | 作用 | 需要 root | 写系统 |
|---|---|---|---|---|
| *（默认）* | `analyze` | 只读体检 | ❌ | ❌ |
| `--install` | `install` | 分析 → 确认 → 转包 + pacman | ✅ | ✅ |
| `-i` `--info` | `analyze` | 同默认 | ❌ | ❌ |
| `-l` `--local` | `local` | 解包到 `~/.local` | ❌ | `~/.local` |
| `-x` `--extract <目录>` | `extract` | 仅解包数据树 | ❌ | 指定目录 |
| `-c` `--convert` | `convert` | 只生成 Arch 包 | ❌ | 输出目录 |
| `-L` `--list-local` | `list-local` | 列出本地装过的包 | ❌ | ❌ |
| `-R` `--remove-local <名>` | `uninstall-local` | 卸载本地包 | ❌ | ✅ |

> `-L` 和 `-R` **在检查 `.deb` 参数之前就处理并退出**，所以它们不需要给 `.deb`。

#### 选项

| 选项 | 变量 | 默认 | 作用 |
|---|---|---|---|
| `-o` `--output <目录>` | `OUTDIR` | 空→`$PWD` | `-c`/`-k` 的输出目录 |
| `-k` `--keep` | `KEEP=1` | 0 | 保留生成的 Arch 包 |
| `-y` `--yes` | `ASSUME_YES=1` | 0 | 不询问 |
| `--overwrite` | `OVERWRITE=1` | 0 | `pacman --overwrite '*'` ⚠️ |
| `--no-desktop` | `MAKE_DESKTOP=0` | 1 | 不建桌面快捷方式 |
| `--no-compat` | `COMPAT_LIBS=0` | 1 | 不补 Debian 专属库、不生成兼容启动器 |
| `--no-scriptlet` | `RUN_SCRIPTLETS=0` | 1 | 不生成 `.INSTALL` |
| `--allow-dangerous` | `ALLOW_DANGER=1` | 0 | 非交互下放行高危包 |
| `--run-remove-hooks` | `RUN_REMOVE_HOOKS=1` | 0 | 卸载时执行 `prerm`/`postrm` |
| `-h` `--help` | — | — | 帮助（`cat <<'EOF'` heredoc） |
| `-v` `--version` | — | — | 打印 `debinstall 2.0.1` |
| `--` | — | — | 选项结束 |

#### `--install` 的行为细节

1. 先跑完整 `analyze_deb`（输出到 stdout）
2. `detect_escalation`
3. 危险门禁：
   - `DANGER=1` 且无 `--yes`：
     - 有 tty → 要求输入 `yes`（不是 `y`），否则 `die`
     - 无 tty 且无 `--allow-dangerous` → `die`
   - `DANGER=0` 且无 `--yes` 且有 tty → 问 `[Y/n]`，`n` 开头才取消
4. `do_install`
   - 转包 → 写 shim → `pacman -U`
   - 收尾顺序**不可调换**：`setup_compat_libs`（补库 + 生成 wrapper 桌面入口）
     → `make_desktop_shortcut`（据此铺桌面快捷方式）→ `fix_electron`
   - `COMPAT_LIBS=1` 时补库复用 `build_arch_pkg` 留下的 `$WORK/root`，不重复解包

> 注意 `-y`/`--yes` **不能**绕过危险门禁 —— 它只跳过普通确认。
> 高危包即便 `-y` 也会走到 `[ -t 0 ]` 分支；无 tty 时仍需 `--allow-dangerous`。

### 1.2 `deb-install-raw`（路线 C，独立脚本）

```
deb-install-raw <pkg.deb>              只分析
deb-install-raw --install <pkg.deb>    铺开到 /
deb-install-raw --list                 列台账
deb-install-raw --uninstall <名>       按台账卸载
deb-install-raw --verbose | -v         详细
deb-install-raw --no-desktop           不建桌面快捷方式
```

- 台账：`/var/lib/deb-install/<名>.list`（一行一个绝对路径）与 `<名>.meta`
- `--uninstall` 非 root 时会 `exec sudo "$0" --uninstall "$名"` 自举
- 依赖 `ar` + `tar`（**不用** `dpkg-deb`）
- 卸载用 `tac` 逆序删，并顺带 `rmdir` 变空的 `/opt/*` 目录（**只动 /opt**）
- ⚠️ `usage()` 是 `sed -n '3,13p' "$0"` —— **改头部注释会移动行号**

### 1.3 `deb-install-open`（终端双击处理器，孤儿）

```
deb-install-open <a.deb> [b.deb ...]
```

逐个：`deb-install <deb>` → 问 `[y/N]` → `y` 则 `deb-install --install <deb>`。
结束时 `read` 等待回车（因为双击场景终端会随进程退出而关闭）。

### 1.4 `deb-install-ui`（GUI）

```
deb-install-ui [<path.deb>]
```

给了路径 → 300ms 后自动开始分析（`GLib.timeout_add(300, self._auto_analyze)`）。

| 环境变量 | 作用 |
|---|---|
| `DEB_INSTALL_TOOL` | 直接指定引擎路径（优先于一切） |
| `DEB_UI_TOPMOST=1` | 窗口置顶（调试用） |

界面上唯一的选项：**「安装后在桌面创建快捷方式」复选框**（默认勾选）。
不勾 → 安装时补 `--no-desktop`。

> GUI **不使用** `-l` / `-c` / `-x` / `-R` / `--overwrite` / `--run-remove-hooks`。
> 只用 `--install`、`--no-desktop`、`--allow-dangerous`。

### 1.5 `install.sh` / `uninstall.sh`（分发安装器）

| 脚本 | 选项 |
|---|---|
| `install.sh` | `PREFIX=<路径>`（默认 `~/.local`）、`--prefix <路径>`、`--no-mime`、`--no-skill`、`--dry-run`、`-h` |
| `uninstall.sh` | `--keep-skill`、`--dry-run`、`--force`、`-h` |

`uninstall.sh` 里 `PREFIX` 是**推导**出来的：`cd "$(dirname $0)/../.." && pwd`。
所以移动 `share/debinstall/` 目录会让卸载找错前缀。

⚠️ 两者的 `usage()` 也是 `sed -n '3,1Xp'`（install 是 `3,13`，uninstall 是 `3,12`），
**行号敏感**。

---

## 2. `debinstall` 全局变量

| 变量 | 初值 | 含义 |
|---|---|---|
| `PROG` | `${0##*/}` | 程序名（用于提示文案） |
| `VERSION` | `2.0.0` | 版本 |
| `SHIMDIR` | `/usr/local/lib/debinstall/shims` | shim 写入点（**与 `_db_run` 里的 PATH 必须一致**） |
| `LOCALROOT` | `${DEBINSTALL_LOCAL_ROOT:-$HOME/.local/debinst}` | 本地安装根 |
| `MODE` | `analyze` | 当前模式 |
| `KEEP` | 0 | 保留 Arch 包 |
| `ASSUME_YES` | 0 | `-y` |
| `RUN_SCRIPTLETS` | 1 | 生成 `.INSTALL` |
| `OVERWRITE` | 0 | `pacman --overwrite` |
| `MAKE_DESKTOP` | 1 | 建桌面快捷方式 |
| `ALLOW_DANGER` | 0 | `--allow-dangerous` |
| `RUN_REMOVE_HOOKS` | 0 | 执行移除钩子 |
| `OUTDIR` | 空 | 输出目录 |
| `EXTRACT_DIR` | 空 | `-x` 目标 |
| `TARGET` | 空 | `-R` 的包名 |
| `DEB` | 空 | `.deb` 绝对路径 |
| `WORK` | 空 | `mktemp -d /tmp/debinstall.XXXXXX` |
| `DANGER` | 0 | 由 `audit_scriptlets` 置 1 |
| `DANGER_RE` | 见 §5.1 | 危险模式正则 |
| `SUDO` | `()` | 提权命令数组 |
| `PACMAN` | `$(command -v pacman)` | pacman 绝对路径 |
| `BUILTIN_MAP` | 见 §5.2 | Debian→Arch 名对照 |
| `_ALT_SHIM_B64` | base64 长串 | 内嵌 shim |
| `_REPO_PKGS` | 空 | `pacman -Slq` 全量包名缓存 |
| `name_of_pkg` | — | **在 `install` 分支里赋值**，供 `do_install` 的完成提示用 |

---

## 3. 函数索引

格式：`函数名(参数)` → 返回值／副作用

### 3.1 输出与基础

| 函数 | 说明 |
|---|---|
| `info(s)` / `ok(s)` / `warn(s)` / `bad(s)` / `msg(s)` | → **stdout** |
| `err(s)` / `die(s)` | → **stderr**（`die` 另 `exit 1`） |
| `have(cmd)` | `command -v` 封装 |
| `usage()` | heredoc 帮助，`exit 0` |
| `cleanup()` | `trap` 目标：删 `$WORK` |

颜色变量 `CR CG CY CC CB CD C0` 在 `[ -t 1 ]` 且非 `NO_COLOR` 时才赋值，否则空串。

### 3.2 提权

| 函数 | 说明 |
|---|---|
| `detect_escalation()` | 填 `$SUDO`。顺序：root→空 / tty+sudo→`(sudo)` / 设 `SUDO_ASKPASS` 后→`(sudo -A)` / pkexec+有 DISPLAY→`(pkexec)` / sudo→`(sudo)` / 否则 `die` |
| `run_root(cmd...)` | `SUDO` 空则直跑，否则 `"${SUDO[@]}" "$@"` |

`SUDO_ASKPASS` 的候选：`$HOME/.local/bin/deb-install-askpass`、`/usr/bin/ksshaskpass`。

### 3.3 安全体检

| 函数 | 说明 |
|---|---|
| `audit_scriptlets(ctl)` | 扫 4 个脚本。打印 `<名> <N> 行`（GUI 抓取），命中 `DANGER_RE` 则 `DANGER=1` 并 `grep -n` 列出命中行。始终 `return 0` |
| `check_top_paths(root)` | 白名单 `opt usr etc var lib lib64 share bin sbin run tmp`，其余 `warn`。打印"写入的顶层路径" |
| `check_desktop_shadow(root)` | 包内 `*.desktop` 若在 `~/.local/share/applications/` 有同名 → `warn` 遮蔽 |
| `check_ll_cli(name)` | 有 `ll-cli` 且列表里 grep 到名字 → `warn` 单实例锁 |
| `deb_desktop_files()` | `dpkg-deb -c` 列出 `usr/share/applications/*.desktop` 的相对路径 |
| `make_desktop_shortcut(srcdir)` | 在 `$(xdg-user-dir DESKTOP)` 建快捷方式。名字优先级 `Name[zh_CN]` > `Name` > 文件名。参数默认 `/usr/share/applications` |
| `fix_electron()` | 找 3 分钟内新增的 `chrome-sandbox`（`/opt`、`/usr/lib` 深 4 层），按 user namespace 可用性设 `0755` 或 `4755` |
| `warn_local_abs_refs(dest)` | 扫本地安装的脚本里的绝对路径引用，有发现**返回 1**并打印 |

### 3.4 alternatives 模拟

| 函数 | 说明 |
|---|---|
| `write_shim(dir, cmd...)` | 把 `_ALT_SHIM_B64` 解码写到 `dir/update-alternatives`（`chmod 755`）。已存在则直接返回 0。`cmd...` 可为 `run_root` |
| `emulate_alternatives_local(dest, ctl, man)` | 解析 `preinst`/`postinst` 里的 `--install`，在 `~/.local/bin/<basename(link)>` 建链。跳过非 `/usr/*` `/opt/*` 的目标，跳过已存在的非符号链接。成功的路径追加进 `man` |

### 3.5 元数据

| 函数 | 说明 |
|---|---|
| `field(name)` | `dpkg-deb --field $DEB <name> \| head -1` |
| `split_version(v)` | → stdout `"<pkgver> <pkgrel>"` |
| `map_arch(debian_arch)` | → stdout Arch 架构 |
| `sanitize_name(s)` | → stdout 合法 Arch 包名 |

### 3.6 依赖

| 函数 | 说明 |
|---|---|
| `elf_sonames(dir)` | → stdout soname 列表（`sort -u`） |
| `shipped_sonames(dir)` | → stdout 包内 `*.so*` 的文件名列表（`sort -u`） |
| `resolve_sonames()` | **stdin 收 soname 列表** → stdout `soname<TAB>包名`。内部一次 `pacman -F` 批量调用 |
| `builtin_lookup(name)` | 查 `BUILTIN_MAP` |
| `map_debian_dep(dep)` | 剥后缀/版本 → 查表 → 同名直通；失败输出空 |
| `in_repo(pkg)` | 缓存式 `pacman -Slq` 成员判断。⚠️ 缓存写进全局 `_REPO_PKGS` |

### 3.7 Debian 补库与兼容启动器（2.0.1）

| 函数 | 说明 |
|---|---|
| `http_get(url)` | curl 优先、wget 兜底；两者都没有则返回 1 |
| `debian_pkg_for_soname(so)` | → stdout `<suite> <包名>`。查 `packages.debian.org` 的 Contents 索引，解析唯一那张 `<table>` 里 `href="/<suite>/<pkg>"` |
| `debian_deb_url(pkg, suite)` | → stdout `.deb` 直链。抓 download 页里的 `pool/…` 相对路径，统一挂 `deb.debian.org`。⚠️ 别用「去掉 `http://host/` 前缀」的写法，会拼出 `…/debian/debian/pool/` |
| `missing_sonames(root, [额外目录…])` | → stdout 缺的 soname。`额外目录` 用来把已补进来的库算作已满足，供多轮循环用 |
| `fetch_debian_libs(pkg, suite)` | 下载 + `dpkg-deb -x` + 平铺 `usr/lib/**/*.so*` 到 `COMPAT_DIR`（保留符号链接） |
| `setup_compat_libs(root)` | 主流程：最多 3 轮「枚举 → 下载 → 复查」，然后调 `make_compat_wrapper` |
| `make_compat_wrapper(root)` | 生成 `~/.local/bin/<desktop名>` 启动器 + 带 `X-DebInstall-Wrapper=1` 的用户级 `.desktop` |

`make_compat_wrapper` 的两个关键启发式：
- `Exec=` 是 `*launch.sh|*start.sh|*run.sh|*.sh` 时，在同目录找与目录同名
  （`/opt/mailmaster` → `mailmaster`）或与 desktop 同名的可执行文件当替身；
  认不出来时明确警告而不是硬闯
- 已存在的 `~/.config/debinstall/<app>.env` **绝不覆盖**（应用专属修复的存放处）

### 3.8 分析与构建

| 函数 | 说明 |
|---|---|
| `analyze_deb()` | 只读体检，输出 5 个段落。**从不 `die`** |
| `make_install_script(ctl, out)` | 生成 `.INSTALL`。无可执行钩子或 `RUN_SCRIPTLETS=0` 时**返回 1** |
| `build_arch_pkg(outdir)` | 完整转包。**最后一行 stdout = 包路径** ⚠️ |
| `do_install()` | 提权 → 转包 → 写 shim → `pacman -U` → 收尾 |
| `do_local()` | 路线 B 全流程 |
| `local_extract(dest, name)` | `dpkg-deb -x` 到 `dest` |
| `rewrite_desktop(src, root, man)` | 改写 `Exec`/`TryExec`/`Path`/`Icon`。**末行 stdout = 改写后文件路径**。⚠️ `man` 参数未被使用 |

---

## 4. 文件格式

### 4.1 `.PKGINFO`（引擎生成）

```ini
# Generated by debinstall 2.0.1
pkgname = hello-debinstall
pkgbase = hello-debinstall
xdata = pkgtype=pkg
pkgver = 1.0.0-1
pkgdesc = a tiny test package
url = https://example.com
builddate = 1789892266
packager = debinstall <debinstall@localhost>
size = 37
arch = x86_64
license = custom
depend = glibc
```

`url` 仅在 `.deb` 有 `Homepage` 时出现。`depend = ` 可重复多行。

### 4.2 `.INSTALL`（引擎生成，示例骨架）

```bash
#!/bin/bash
# Generated by debinstall — 运行 .deb 自带的维护脚本（尽力而为，失败不影响安装）

_db_run() {
    local label="$1" b64="$2" action="$3" ver="$4"
    local d; d="$(mktemp -d)" || return 0
    printf '%s' "$b64" | base64 -d > "$d/s" 2>/dev/null || { rm -rf "$d"; return 0; }
    chmod 755 "$d/s"
    if [ -d /usr/local/lib/debinstall/shims ]; then
        export PATH="/usr/local/lib/debinstall/shims:$PATH"
    fi
    export DEBIAN_FRONTEND=noninteractive
    export DEBINSTALL_SCRIPTLET="$label"
    bash "$d/s" "$action" "$ver" >/dev/null 2>&1 || true
    rm -rf "$d"
    return 0
}

postinst_B64() { printf %s 'IyEvYmluL3NoCg...'; }

post_install() { _db_run "postinst" "$(postinst_B64)" "configure" "$1"; }
post_upgrade() { _db_run "postinst" "$(postinst_B64)" "configure" "$2"; }
```

钩子名映射：`pre_install`/`pre_upgrade`（preinst）、`post_install`/`post_upgrade`（postinst）、
`pre_remove`（prerm）、`post_remove`（postrm）。后两个仅 `--run-remove-hooks` 时生成。

### 4.3 包内条目顺序（pacman 要求）

```
.PKGINFO
[.INSTALL]
.MTREE
usr/
usr/bin/
usr/bin/xxx
...
```

元数据在前，文件树在后。

### 4.4 `update-alternatives` shim 的台账

`$DEBINSTALL_ALT_DB/links`（默认 `/var/lib/debinstall/alternatives/links`）：

```
名<TAB>链接路径<TAB>目标路径
figlet	/usr/bin/figlet	/usr/bin/figlet-utf8
```

### 4.5 本地安装（路线 B）的记帐文件

`~/.local/debinst/<包名>/.debinstall-manifest` —— 一行一个绝对路径，卸载时逐个删。

```
/home/user/.local/bin/figlet
/home/user/.local/share/applications/foo.desktop
/home/user/.local/share/icons/hicolor/48x48/apps/foo.png
```

`~/.local/debinst/<包名>/.debinstall-info`：

```ini
name=figlet
version=2.2.5-3
source=/home/user/Downloads/figlet_2.2.5-3_amd64.deb
installed=2026-09-20T16:20:11+08:00
```

> `-L` 读的是 `.debinstall-info` 的 `version=` 行（`sed -n 's/^version=//p'`）。

### 4.6 路线 C 的台账

`/var/lib/deb-install/<包名>.list` —— 一行一个绝对路径（`tar -tf` 输出去掉 `./` 前缀、
过滤掉目录行，另加两行：`/usr/bin/<名>` 符号链接、桌面快捷方式路径）。

`/var/lib/deb-install/<包名>.meta`：

```ini
name=google-chrome-stable
version=120.0.6099.109-1
time=2026-09-20 16:20:11
deb=/home/user/Downloads/google-chrome-stable_current_amd64.deb
```

---

## 5. 正则与对照表

### 5.1 `DANGER_RE`（9 条分支，POSIX ERE）

```
rm[[:space:]]+-[a-zA-Z]*[rR][a-zA-Z]*[[:space:]]+(--[[:space:]]+)?/([[:space:]]|$)
|rm[[:space:]]+-[rR][a-zA-Z]*[[:space:]]+-[a-zA-Z]*[[:space:]]+/([[:space:]]|$)
|dd[[:space:]][^|]*of=/dev/
|mkfs\.
|>[[:space:]]*/dev/(sd|nvme|vd|mmcblk)
|(curl|wget)[^|]*\|[[:space:]]*(ba|z|k)?sh
|chown[[:space:]]+-R[[:space:]]+[^[:space:]]+[[:space:]]+/([[:space:]]|$)
|chmod[[:space:]]+-R[[:space:]]+[0-7]*777[[:space:]]+/
|:\(\)\{[[:space:]]*:\|:&
```

**验证过的边界**（改这条正则后应重跑这些用例）：

命中：`rm -rf /`、`rm -rf -- /`、`rm -r -f /`、`dd if=… of=/dev/sda`、
`mkfs.ext4 /dev/sda1`、`echo x > /dev/sda`、`curl … | sh`、`wget … | bash`、
`chown -R nobody /`、`chmod -R 0777 /`、`:(){ :|:& };:`

放行：`rm -f /usr/share/doc/x/README`、`rm -rf /opt/MyApp/old`、
`chmod 755 /usr/bin/foo`、`chown root:root /usr/bin/foo`、
`curl -s https://api.example.com/ping > /dev/null`、
`dd if=/dev/zero of=/tmp/blank bs=1k count=1`、
`update-alternatives --install /usr/bin/figlet figlet /usr/bin/figlet-utf8 100`

### 5.2 `BUILTIN_MAP`（Debian → Arch，78 条）

空白分隔两列，`awk '$1 == n { print $2 }'` 查找。

<details>
<summary>展开全部条目</summary>

| Debian | Arch | | Debian | Arch |
|---|---|---|---|---|
| libc6 | glibc | | libgl1 | mesa |
| libc6-dev | glibc | | libegl1 | mesa |
| libgcc1 | gcc-libs | | libglx0 | mesa |
| libgcc-s1 | gcc-libs | | libglu1-mesa | glu |
| libstdc++6 | gcc-libs | | libasound2 | alsa-lib |
| libncurses6 | ncurses | | libasound2-plugins | alsa-plugins |
| libncursesw6 | ncurses | | libnss3 | nss |
| libtinfo6 | ncurses | | libnspr4 | nspr |
| zlib1g | zlib | | libatk1.0-0 | atk |
| libz1 | zlib | | libatk-bridge2.0-0 | at-spi2-core |
| libpcre3 | pcre | | libatspi2.0-0 | at-spi2-core |
| libpcre2-8-0 | pcre2 | | libcups2 | libcups |
| libssl3 | openssl | | libdrm2 | libdrm |
| libssl1.1 | openssl | | libxkbcommon0 | libxkbcommon |
| libcrypto3 | openssl | | libsecret-1-0 | libsecret |
| libcurl4 | curl | | libnotify4 | libnotify |
| libcurl3-gnutls | curl | | gconf-service | gconf |
| libgnutls30 | gnutls | | libappindicator3-1 | libappindicator-gtk3 |
| libsystemd0 | systemd-libs | | libappindicator1 | libappindicator-gtk3 |
| libudev1 | systemd-libs | | libayatana-appindicator3-1 | libayatana-appindicator |
| python3 | python | | libdbusmenu-glib4 | libdbusmenu-glib |
| python | python | | libdbusmenu-gtk3-4 | libdbusmenu-gtk3 |
| perl | perl | | gvfs-bin | gvfs |
| openjdk-17-jre-headless | jre-openjdk-headless | | libu2f-udev | libu2f-host |
| default-jre | java-runtime | | libgnome-keyring0 | libgnome-keyring |
| default-jre-headless | java-runtime-headless | | libgtk2.0-0 | gtk2 |
| fonts-dejavu-core | ttf-dejavu | | libgtk-3-0 | gtk3 |
| fonts-dejavu | fonts-dejavu | | libgtk-4-1 | gtk4 |
| xdg-utils | xdg-utils | | libqt5core5a | qt5-base |
| desktop-file-utils | desktop-file-utils | | libqt5gui5 | qt5-base |
| shared-mime-info | shared-mime-info | | libqt5widgets5 | qt5-base |
| hicolor-icon-theme | hicolor-icon-theme | | libqt5network5 | qt5-base |
| ca-certificates | ca-certificates | | libqt5dbus5 | qt5-base |
| fonts-liberation | ttf-liberation | | libqt5x11extras5 | qt5-x11extras |
| libx11-6 | libx11 | | libqt5svg5 | qt5-svg |
| libxext6 | libxext | | libqt6core6 | qt6-base |
| libxss1 | libxss | | libqt6gui6 | qt6-base |
| libxtst6 | libxtst | | libqt6widgets6 | qt6-base |
| libgbm1 | mesa | | libqt6network6 | qt6-base |
| | | | libqt6dbus6 | qt6-base |
| | | | libqt6svg6 | qt6-svg |

</details>

### 5.3 GUI 侧的匹配模式（**改引擎文案前必须核对**）

```python
RE_PKG    = re.compile(r"^\s*包名\s+(\S+)")
RE_VER    = re.compile(r"^\s*版本\s+(\S+)")
RE_ARCH   = re.compile(r"^\s*架构\s+(\S+)")
RE_SCRIPT = re.compile(r"^\s*(preinst|postinst|prerm|postrm)\s+(\d+)\s*行")
```

子串匹配（`in`）：`没有安装脚本`、`高危`、`所有动态库已满足`、`缺失库`、
`没找到可执行文件`、`没有 desktop 遮蔽冲突`、`会遮蔽系统级`、`玲珑里已装`

### 5.4 `pacman -F` 输出格式（awk 解析依赖它，实测）

```
core/glibc 2.44+r24+g16be1518495f-1 [已安装]
    usr/lib/libc.so.6
core/lib32-glibc 2.44+r24+g16be1518495f-1
    usr/lib32/libc.so.6
extra/aarch64-linux-gnu-glibc 2.44-1
    usr/aarch64-linux-gnu/lib/libc.so.6
```

- 头行 `repo/包名 版本 [已安装]` —— 取包名时截到第一个空白，所以 `[已安装]` 无害
- 路径行缩进 4 空格
- **只接受 `usr/lib/` 开头**；`usr/lib32/` 单独处理；`usr/lib64/` 与
  `usr/<三元组>/lib/` 一律丢弃（交叉工具链）

---

## 6. 环境变量汇总

| 变量 | 被谁读 | 作用 |
|---|---|---|
| `DEBINSTALL_LOCAL_ROOT` | `debinstall` | 覆盖本地安装根（默认 `~/.local/debinst`） |
| `DEBINSTALL_COMPAT_DIR` | `debinstall` | 覆盖兼容库目录（默认 `~/.local/lib/debcompat`） |
| `DEBINSTALL_COMPAT_ENV` | `debinstall` | 覆盖应用专属修复目录（默认 `~/.config/debinstall`） |
| `DEBINSTALL_KEEP_DIR_PERM` | `debinstall` | 设了就跳过目录权限规范化（保留 .deb 原本的 775） |
| `DEBINSTALL_ALT_DB` | shim | 覆盖 alternativ es 台账目录 |
| `DEBINSTALL_SCRIPTLET` | shim（被设置） | 当前脚本名，调试用 |
| `DEB_INSTALL_TOOL` | `deb-install-ui` | 指定引擎路径 |
| `DEB_UI_TOPMOST` | `deb-install-ui` | `=1` 窗口置顶 |
| `SUDO_ASKPASS` | `debinstall` | 图形化密码程序；未设则自动探测 |
| `NO_COLOR` | 全部输出函数 | 设了就禁用 ANSI 颜色 |
| `XDG_RUNTIME_DIR` | `check_ll_cli` | 兜底 `/run/user/$(id -u)` |
| `PATH` | `.INSTALL` 的 `_db_run` | 前置 `SHIMDIR` 让 shim 生效 |

---

## 7. 外部命令依赖

| 命令 | 来自包 | 必需性 |
|---|---|---|
| `dpkg-deb` | `dpkg` | **必需**（拆包与读元数据） |
| `bsdtar` | `libarchive` | **必需**（打包与 `.MTREE`） |
| `fakeroot` | `fakeroot` | **必需**（打包时伪造 root 属主） |
| `zstd` | `zstd` | **必需**（压缩包） |
| `pacman` | `pacman` | **必需** |
| `readelf` | `binutils` | 必需（读 `DT_NEEDED`） |
| `ar` | `binutils` | 仅 `deb-install-raw` 用 |
| `unshare` | `util-linux` | 可选（探测 user namespace，决定 chrome-sandbox 权限） |
| `xdg-user-dir` | `xdg-user-dirs` | 可选（找桌面目录） |
| `update-desktop-database` | `desktop-file-utils` | 可选 |
| `gtk-update-icon-cache` | `gtk-update-icon-cache` | 可选 |
| `pkexec` | `polkit` | 可选（无 sudo 时的图形提权兜底） |
| `ll-cli` | 玲珑 | 可选（冲突检测） |

GUI 额外：`python3`（**必须 `/usr/bin/python3`**）+ `python-gobject` + `gtk3`。

> ⚠️ GUI 脚本 shebang 是 `#!/usr/bin/python3`，**不要改成 `#!/usr/bin/env python3`**。
> `gi` 是 pacman 装在系统 python 下的；走 `env` 可能命中 venv/conda 的 python（无 `gi`），
> 表现为"找不到 gi"直接崩。
