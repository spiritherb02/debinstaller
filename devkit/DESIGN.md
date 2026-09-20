# debinstall 逻辑说明书

> 版本 2.0.0 ｜ 目标平台 Arch Linux（pacman）｜ 引擎语言 POSIX-ish bash + Python3(GTK3)
>
> 本文描述**这套工具当前的实际逻辑**，不是设计愿景。所有算法、字段名、正则、
> 命令都对着 2.0.0 的源码核对过。要改代码前请先读完第 7 章（接口契约）和第 9 章
> （已知缺陷），那两章是踩过坑的地方。

---

## 0. 怎么读这份文档

| 你是 | 读这些 |
|---|---|
| 第一次接触这套代码，要接手开发 | 第 2 章（路线）→ 第 4 章（数据流）→ 第 9 章（缺陷） |
| 要改某个具体功能 | 第 5 章找到对应算法 → 第 8 章确认不变量不能破 |
| 要动输出文案 | **先读第 7 章**，GUI 靠文案匹配，改字会静默弄坏图形界面 |
| 要加新的 .deb 来源或新发行版 | 第 10 章（扩展点） |

配套文件：

- `REFERENCE.md` —— 速查表：全部命令行选项、内部函数签名、文件格式、环境变量
- `HANDOFF.md` —— 接手手册：环境搭建、测试方法、常见改动配方、待办
- `AI-PROMPT.md` —— 一段可直接粘贴给其他 AI 的引导语
- `src/` —— 源码快照（2.0.0）

---

## 1. 它解决什么问题，以及为什么这样设计

### 1.1 问题

Arch 与 Debian 的包管理是两套互不兼容的东西。大量软件只发 `.deb`
（Chrome、Edge、VS Code、JetBrains、国产软件……）。Arch 用户的常见土办法都有硬伤：

| 土办法 | 硬伤 |
|---|---|
| `bsdtar -xf x.deb -C /` | 系统不认识它。卸载靠手工删，残留无法审计 |
| 找 AUR | 不保证有，不保证同步 |
| `pacman -U --force` 装 Debian 包 | 污染 pacman 数据库 |

### 1.2 本工具的核心主张

**把 `.deb` 转换成一个真正的 Arch 包，再交给 `pacman -U` 安装。**
这样装出来的东西被 pacman 完整跟踪，`-Q`/`-Ql`/`-Qo`/`-R` 全部正常工作，
不产生"野文件"。

### 1.3 三条不可动摇的设计原则

1. **默认只读。** 不带 `--install` / `-l` 就绝不写系统。这不是"顺手加的安全开关"，
   而是核心设计 —— `.deb` 自带的 `postinst` 是以 root 执行的任意 shell，
   不给人看一眼就装是不负责任的。
2. **先体检后动手。** `--install` 内部会**先跑一遍完整的只读分析**，再问确认，
   最后才写盘。分析逻辑只有一份，不可能出现"分析说没事、安装时却做了别的"。
3. **宁可少做，不做错事。** 移除阶段的钩子（`prerm`/`postrm`）默认**不执行**。
   理由见 6.3。

### 1.4 为什么不用 dpkg / alien

- `dpkg` 在 Arch 上跑不起来（依赖 Debian 的 `dpkg` 数据库布局）。
- `alien` 只能转换**源码形态**的元数据，不解析 ELF 依赖，且在 Arch 上没有对应实现。
- 自己从 `dpkg-deb` 输出的 tar 流重建，是唯一能**同时拿到真实依赖关系**的做法：
  因为 `.deb` 里的二进制是**为 Debian 编译的**，它 `DT_NEEDED` 的那些 `lib*.so.N`
  在 Arch 上存在与否，必须逐个查证 —— 这就是第 5.3 章那套 ELF→pacman 反查的由来。

### 1.5 `.AppImage` 是另一回事，只长在 GUI 上

AppImage 自称"一次打包，到处运行"，它**已经把依赖打在包里了**，所以
`.deb` 那条"解析依赖 → 转成原生包"的主张在这儿没有用武之地。
GUI 对它做的事只有三件：只读看一眼（`file`/`7z`，**绝不执行**）、
移到 `~/Applications`、把图标和菜单项注册好。不需要 root，也不碰引擎。

细节和风险边界见 **§7.7**。第 2 章那"三条路线"说的是 `.deb`，不含 AppImage。

---

## 2. 三条安装路线

工具里存在**三条**互不相同的安装路线。它们不是"同一功能的三个版本"，取舍不同。

### 路线 A — 转 Arch 包 → pacman　（`debinstall --install` / `-c`）

```
.deb → 解包 → 推导依赖 → 生成 .PKGINFO/.MTREE/.INSTALL → .pkg.tar.zst → pacman -U
```

- **装完被 pacman 跟踪**：`pacman -Q` 查得到，`pacman -R` 卸得掉
- 有**真实依赖解析**（ELF soname → pacman 文件库反查）
- 需要 root
- 偶尔因文件冲突失败（用 `--overwrite` 或退回路线 B）

**这是首选路线。**

### 路线 B — 本地安装到 `~/.local`　（`debinstall -l`）

```
.deb → 解包到 ~/.local/debinst/<name>/ → 可执行软链到 ~/.local/bin
     → 图标/desktop 改写路径后装到 ~/.local/ → 模拟 update-alternatives
```

- **不需要 root**
- 不进 pacman 数据库（用自家 manifest 记台账）
- 适合：没有 sudo、试用、被 pacman 的文件冲突挡住时
- 代价：见 5.7 的固有局限（绝对路径引用会断）

### 路线 C — 铺开到 `/` + 台账　（`deb-install-raw`，独立脚本）

```
ar x → control.tar.* / data.tar.* → sudo tar xf data.tar.* -C /
     → 台账写 /var/lib/deb-install/<pkg>.list
```

- **不转 Arch 包**，直接把 Debian 的文件树铺到根目录
- 兼容性最好，几乎什么都能装上
- **系统完全不认识它**：卸载只能靠自家台账 `--uninstall`
- 这是最早那版工具的形态，保留作路线 A 失败时的兜底

### 路线对比

| | A 转包+pacman | B 本地 `~/.local` | C 铺开到 `/` |
|---|---|---|---|
| pacman 记账 | ✅ | ❌ | ❌ |
| 依赖解析 | ✅ 自动 | ⚠️ 部分 | ❌ 无 |
| 需要 root | ✅ | ❌ | ✅ |
| 卸载 | `pacman -R` | `debinstall -R` | `deb-install-raw --uninstall` |
| 台账位置 | pacman 数据库 | `~/.local/debinst/<n>/` | `/var/lib/deb-install/` |
| 兼容性 | 中 | 低 | 高 |
| 实现文件 | `debinstall` | `debinstall` | `deb-install-raw` |

---

## 3. 模块清单与职责

| 文件 | 语言 | 行数 | 职责 | 被谁调用 |
|---|---|---|---|---|
| `debinstall` | bash | 1149 | **主引擎**。7 种模式，路线 A/B 的全部逻辑 | GUI、open、用户 |
| `deb-install` | symlink | — | → `debinstall`，历史名字 | GUI 的默认查找目标 |
| `deb-install-ui` | Python3+GTK3 | 530 | 图形界面。包一层引擎的 analyze + install | 文件管理器双击 |
| `deb-install-askpass` | Python3+GTK3 | 123 | 图形化 sudo 密码框 | 引擎（经 `SUDO_ASKPASS`） |
| `deb-install-open` | bash | 72 | 终端里的双击处理器（分析→询问→暂停） | **无人调用（孤儿）** |
| `deb-install-raw` | bash | 339 | 路线 C 的独立实现 | **无人调用（孤儿）** |
| `deb-install.desktop` | ini | 17 | 桌面入口，声明 `.deb` MIME | 桌面环境 |

> **重要事实：`deb-install-open` 和 `deb-install-raw` 目前是孤儿。**
> `.deb` 的双击关联指向 `deb-install.desktop`，而它的 `Exec=` 是 `deb-install-ui %F`。
> 两个孤儿脚本都是独立入口，需要用户手动调用。要么把它们接进流程，要么删掉 ——
> 这是第 9 章列的设计债之一。

### 3.1 引用关系图

```
              ┌─────────────────────┐
  双击 .deb → │ deb-install.desktop │ Exec=deb-install-ui %F
              └──────────┬──────────┘
                         ↓
              ┌─────────────────────┐  子进程调用（stdout 逐行解析）
              │   deb-install-ui    │ ────────────────────────┐
              └──────────┬──────────┘                          ↓
                         │ DEB_INSTALL_TOOL / PATH     ┌────────────────┐
                         └────────────────────────────→│   debinstall   │
                                                       │   （主引擎）    │
                                                       └───────┬────────┘
                                                               │ 无 tty 时
                                              SUDO_ASKPASS     ↓
                                                       ┌──────────────────────┐
                                                       │ deb-install-askpass  │
                                                       └──────────────────────┘

  孤儿（独立入口，无引用）：deb-install-open（终端双击）
                            deb-install-raw （路线 C）
```

---

## 4. 核心数据流：一次 `--install` 的完整时序

这是全系统最重要的一条路径，把它背下来基本就懂了大半。

```
用户: debinstall --install foo.deb
  │
  ├─ 参数解析 → MODE=install, DEB=foo.deb（readlink -f 绝对化）
  ├─ 依赖检查：dpkg-deb bsdtar fakeroot zstd pacman 都在吗
  ├─ WORK=$(mktemp -d /tmp/debinstall.XXXXXX)  +  trap 退出时清掉
  │
  ├─【阶段 1】analyze_deb()          ← 只读，不改系统
  │    ├─ 临时解包到 $S/root 与 $S/ctl（自己的临时目录，用完即删）
  │    ├─ 打印「包信息」：包名/版本/架构/Arch 映射/架构是否匹配本机
  │    ├─ audit_scriptlets()  ← 危险正则扫描，命中则置全局 DANGER=1
  │    ├─ check_top_paths()   ← 会往哪些顶层目录写
  │    ├─ elf_sonames → shipped 相减 → resolve_sonames → 逐条打印映射
  │    └─ check_desktop_shadow() / check_ll_cli()
  │
  ├─【阶段 2】门禁
  │    ├─ detect_escalation()  ← 决定 SUDO 用 sudo / sudo -A / pkexec
  │    ├─ name_of_pkg=$(sanitize_name ...)
  │    └─ if DANGER:
  │          ├─ 有 tty  → 要求手输 yes，否则 die
  │          └─ 无 tty  → 除非 --allow-dangerous，否则 die  ← 见 6.2
  │       elif 非 --yes 且有 tty:
  │          └─ 问 [Y/n]
  │
  └─【阶段 3】do_install()
       ├─ pkg=$(build_arch_pkg "$WORK/out" | tail -1)     ← 见 5.4
       ├─ write_shim "$SHIMDIR" run_root                  ← 落 alternatives shim
       ├─ run_root pacman -U --noconfirm [--overwrite '*'] "$pkg"
       ├─ 成功 → make_desktop_shortcut()（可选）
       │        fix_electron()（chrome-sandbox 权限）
       │        提示 ELECTRON_RUN_AS_NODE 污染
       └─ 失败 → 打印两条出路（改 -l / 加 --overwrite）
                把生成的包留在 $PWD 供人工处理
```

### 4.1 一个容易忽略的细节：`build_arch_pkg` 的返回值靠 stdout 末行

```bash
pkg=$(build_arch_pkg "$WORK/out" | tail -1)
```

`build_arch_pkg` 全程用 `info`/`ok` 往 **stdout** 打进度，最后 `printf '%s\n' "$outdir/$pkgfile"`
把包路径作为**最后一行**输出。调用方用 `tail -1` 取。

**这是一条隐式契约**：任何往这个函数末尾追加 stdout 输出的改动都会破坏它。
REFERENCE.md 里把这点标了 ⚠️。

---

## 5. 算法详解

### 5.1 拆包

```bash
dpkg-deb -x "$DEB" "$root"    # data 树（文件本体）
dpkg-deb -e "$DEB" "$ctl"     # control 树（preinst/postinst/prerm/postrm/control）
```

用 `dpkg-deb` 而不是 `ar + tar` 手工拆。理由：`dpkg-deb` 自动处理
`control.tar.zst`/`.xz`/`.gz`/`.lzma` 各种压缩格式，而 `ar x` 之后还要自己
探测后缀名。路线 C 用的是手工拆（`ar`），是本工具里唯一需要 `ar` 的地方。

元数据读取：

```bash
field() { dpkg-deb --field "$DEB" "$1" 2>/dev/null | head -1 || true; }
```

### 5.2 元数据映射：Debian → Arch

#### 版本号 `split_version`

Debian 版本形如 `[epoch:]upstream[-revision]`，Arch 是 `pkgver-pkgrel`：

```
1:2.3.4-5        → epoch 丢弃；up=2.3.4  rev=5
1.9.0            → up=1.9.0    rev=1（无 revision 时默认为 1）
2.0.0~beta1-2    → up=2.0.0.beta1（~ 等非法字符 → .） rev=2
```

规则：

- 丢弃 epoch（第一个 `:` 之前）
- 最后一个 `-` 之后是 revision，没有则取 `1`
- `pkgver` 允许 `A-Za-z0-9._+`，其余字符统一替换成 `.`
- `pkgrel` 允许 `A-Za-z0-9.`，其余替换成 `.`
- 结果为空则回退成 `1`

> ⚠️ 注意 `pkgver` 不能含 `-` 和 `:`，这是 pacman 的硬性要求，所以必须净化。
> 但 `+` 是合法的，别一起干掉（很多包版本里有 `+`，比如 `2.44+r24+g16be1518495f`）。

#### 架构 `map_arch`

| Debian | Arch |
|---|---|
| `amd64`, `x86_64` | `x86_64` |
| `arm64`, `aarch64` | `aarch64` |
| `i386`, `i486`, `i586`, `i686` | `i686` |
| `armhf`, `armv7l` | `armv7h` |
| `all`, `any`, `noarch` | `any` |
| 其它 | 原样转小写（大概率装不上） |

匹配判定：`aarch != any && aarch != $(uname -m)` → 警告但仍继续转换。

#### 包名 `sanitize_name`

小写化 → 非 `[a-z0-9@._+-]` 换成 `-` → 折叠连续 `-` → 去首尾 `-`。

然后一次**冲突消解**：

```bash
if in_repo "$name"; then
    warn "仓库里已有同名包 $name，改名安装为 ${name}-deb 以避免混淆"
    name="${name}-deb"
fi
```

理由：如果 Arch 仓库里已经有个叫 `code` 的包，再装一个也叫 `code` 的
会让人分不清 `pacman -R code` 卸的是哪个。加 `-deb` 后缀明确区分。

### 5.3 依赖推导（本工具最核心的算法）

`.deb` 的 `Depends:` 写的是 **Debian 包名**（`libc6`、`libgtk-3-0`），
Arch 上叫 `glibc`、`gtk3`。按名字翻译是不可能的（没有可靠对照表，
而且同一个 Debian 包在不同架构上拆法还不一样）。

**正确做法是绕过包名，直接看二进制要什么库。**

```
1. 找出解包树里所有 ELF
     条件：有可执行位 或 名字匹配 *.so / *.so.*
     过滤：跳过符号链接（避免重复）
     判定：读前 4 字节 == 7f454c46（\x7fELF）

2. readelf -d <elf> | 抽 (NEEDED) 里的 soname
   → 得到形如 libnss3.so / libc.so.6 的清单

3. 减掉包自己带的 soname（shipped_sonames）
   否则会把「包内自带的库」误判成外部依赖

4. soname → Arch 包名：pacman -F 反查

5. 再补上 .deb 声明的 Depends/Pre-Depends 里能映射到的那部分
   （处理那些「没有 ELF 但确实要装」的依赖，如 fonts-*、xdg-utils）

6. 去重、排除自身、只保留仓库里真实存在的（in_repo）
```

#### 第 4 步 `pacman -F` 反查的两个关键细节

**细节一：必须批量调用。**

`pacman -F` 每次调用都要加载文件数据库，单价极高。实测：

| 方式 | 4 个库 | 14 个库 |
|---|---|---|
| 逐个调用 | 33.7s | ~2min |
| 一次批量 | 9.2s | ~15s |

所以 `resolve_sonames` 的设计是：**soname 列表走 stdin，一次性传给 `pacman -F`**。

**细节二：必须过滤交叉工具链。**

`pacman -F libc.so.6` 的真实输出（实测）：

```
core/glibc 2.44+r24+g16be1518495f-1 [已安装]
    usr/lib/libc.so.6
core/lib32-glibc 2.44+r24+g16be1518495f-1
    usr/lib32/libc.so.6
extra/aarch64-linux-gnu-glibc 2.44-1
    usr/aarch64-linux-gnu/lib/libc.so.6
extra/riscv64-linux-gnu-glibc 2.44-1 (risc-v)
    usr/riscv64-linux-gnu/lib/libc.so.6
archlinuxcn/x86_64-linux-gnu-glibc 2.44+r24+g16be1518495f-1
    usr/x86_64-linux-gnu/lib/libc.so.6
```

如果不加过滤，`libc.so.6` 可能被解析成 `aarch64-linux-gnu-glibc`。

awk 里的过滤与优先级：

```
只认 usr/lib/ 开头的路径
    ↓
usr/lib32/       → 单独进 M32 桶（32 位运行库）
usr/lib64/       → 丢弃（arm/riscv 交叉工具链的库常在这，会误匹配）
usr/x86_64-linux-gnu/... → 天然被丢弃（不以 usr/lib/ 开头）
    ↓
仓库优先级：core > extra > multilib > 其它(第三方) > lib32
```

输出格式：`<soname>\t<Arch包名>`，每行一条。

> **注意 awk 的解析对 `pacman -F` 的输出格式有硬依赖**（`repo/pkg ver` 头行 +
> 缩进路径行）。它能容忍 `[已安装]` 这类本地化后缀，因为取包名时是
> 「截到第一个空白为止」。但**如果 pacman 改了输出格式，这里会静默失效**
> （解析不出任何映射 → 依赖为空 → 装出来的包缺依赖）。见第 8 章的自检建议。

#### 第 5 步 `BUILTIN_MAP` 内建对照表

处理"推不出 soname"的依赖，约 78 条。例子：

```
libc6            → glibc
libc6-dev        → glibc
libgcc-s1        → gcc-libs
zlib1g           → zlib
libnss3          → nss
libgtk-3-0       → gtk3
libasound2       → alsa-lib
fonts-dejavu-core → ttf-dejavu
default-jre      → java-runtime
python3          → python
```

`map_debian_dep` 的顺序：

1. 剥掉 `:any` / `:amd64` 后缀、版本约束 `(>= 1.2)`、空白
2. 查 `BUILTIN_MAP`
3. 没有则看 Arch 仓库里是否**同名存在**（`pacman -Ssq "^name$"`），有则直通
4. 都没有 → 放弃（返回空，由第 6 步的 `in_repo` 兜底再筛一次）

#### 第 6 步 `in_repo` 的性能处理

```bash
_REPO_PKGS=""          # 缓存
in_repo() {
    if [ -z "$_REPO_PKGS" ]; then
        _REPO_PKGS=$(pacman -Slq 2>/dev/null | sort -u)   # 全量包名，约 1s
        [ -n "$_REPO_PKGS" ] || { _REPO_PKGS="__EMPTY__"; return 1; }
    fi
    grep -qxF "$1" <<<"$_REPO_PKGS"
}
```

**首次调用一次取全量包名列表，之后纯本地字符串比对。**
对比逐包 `pacman -Ssq` 是 N 次进程启动。

> ⚠️ **已知缺陷**：`_REPO_PKGS` 是函数外部的全局变量，且缓存以 `_REPO_PKGS` 非空为准。
> `__EMPTY__` 这个哨兵值设计用来区分"还没查过"和"查了但是空的"，逻辑是对的。
> 但这个缓存在**同一个进程内不会失效** —— 如果 `pacman -Sy` 更新了仓库，
> 同一次运行里的判断仍用旧数据。对本工具的短生命周期来说无害。

### 5.4 生成 Arch 包

这是第二核心算法。产物必须让 pacman 认。

#### 5.4.1 `.PKGINFO` 字段

写在解包树的根 `$root/.PKGINFO`：

```ini
# Generated by debinstall 2.0.0
pkgname = <sanitize_name 后的名字>
pkgbase = <同上>
xdata = pkgtype=pkg
pkgver = <pkgver>-<pkgrel>
pkgdesc = <描述，换行压成空格，截断 200 字符>
url = <Homepage>                    # 有才写
builddate = <date +%s>
packager = debinstall <debinstall@localhost>
size = <du -sb 字节数>
arch = <映射后的架构>
license = custom
depend = <Arch 包名>                 # 可重复多行
```

`xdata = pkgtype=pkg` 不能少：pacman 靠它区分包类型。

#### 5.4.2 `.INSTALL`（安装脚本钩子）

见 5.5。

#### 5.4.3 `.MTREE` 与打包

实际打包在子脚本 `$WORK/_build.sh` 里跑，外面套 `fakeroot`：

```bash
fakeroot -- bash "$WORK/_build.sh" "$root" "$outdir/$pkgfile"
```

子脚本做的两件事：

```bash
export LC_ALL=C LANG=C

opt=()
[ -f .INSTALL ] && opt+=(.INSTALL)

mapfile -t tops < <(find . -mindepth 1 -maxdepth 1 \
        ! -name '.PKGINFO' ! -name '.INSTALL' ! -name '.MTREE' -printf '%P\n' | LC_ALL=C sort)

# 1) .MTREE（不含自身）
{ printf '%s\0' .PKGINFO "${opt[@]}" "${tops[@]}"; } \
  | bsdtar -cf - --format=mtree \
        --options='!all,use-set,type,uid,gid,mode,time,size,sha256,link' \
        --null --files-from - \
  | gzip -c -f -n > .MTREE

# 2) 真正的包：元数据在前，文件树在后
{ printf '%s\0' .PKGINFO "${opt[@]}" .MTREE "${tops[@]}"; } \
  | bsdtar --no-fflags --no-read-sparse -cf - --null --files-from - \
  | zstd -q -c -T0 > "$2"
```

**三个必须理解的点：**

1. **顺序有意义。** pacman 读包时先解析头部的 `.PKGINFO`，所以元数据必须排在文件树前面。
2. **`.MTREE` 不包含自己。** 生成 `.MTREE` 时的清单里没有 `.MTREE`；但打最终包时
   `.MTREE` 要被放进去。所以两次的 `printf` 内容不同。
3. **绝对不能用 `-n`。** 见 5.4.4。

`--options` 里的字段清单决定了 `.MTREE` 记录哪些属性。`sha256` 让 pacman 能做
`-Qk` 完整性校验。

#### 5.4.4 ⚠️ 最危险的一个坑：`bsdtar` 的 `-n` 不是 GNU tar 的 `-n`

```bash
# GNU tar:  -n = --seek    （归档可检索）
# bsdtar:   -n = --no-recursion
```

**同一个字母，完全相反的含义。** 实测：

```bash
mkdir -p nt/sub && echo a > nt/a.txt && echo b > nt/sub/b.txt
( cd nt && bsdtar -cf - .    ) | bsdtar -tf -   # → ./  ./a.txt  ./sub/  ./sub/b.txt
( cd nt && bsdtar -cf - -n . ) | bsdtar -tf -   # → ./                  ← 只剩空壳！
```

如果误加了 `-n`，**打出来的包是空的，但不会报错**。这就是为什么
`build_arch_pkg` 末尾要做条目数自检（见 8.1）。

#### 5.4.5 打包自检

```bash
n_src=$(find "$root" -mindepth 1 | wc -l)
n_pkg=$(bsdtar -tf "$outdir/$pkgfile" | wc -l)
if [ "$n_pkg" -lt "$n_src" ]; then
    err "打包自检失败：源树 $n_src 个条目，包里只有 $n_pkg 个。"
    err "（这是 bug，已中止，以免装出一个空包）"
    exit 1
fi
for m in .PKGINFO .MTREE; do
    bsdtar -tf "$outdir/$pkgfile" | grep -qx "$m" || die "打包自检失败：缺少 $m"
done
```

这道自检就是被 5.4.4 那个坑逼出来的。**改打包逻辑时不要删掉它。**

### 5.5 安装脚本注入（`.INSTALL`）

Debian 的维护脚本有 4 个，在 Arch 里对应 `.INSTALL` 里的钩子函数：

| Debian 脚本 | 运行时机 | Arch 钩子 | 传入参数 |
|---|---|---|---|
| `preinst` | 解包前 | `pre_install` / `pre_upgrade` | `install` / `upgrade` |
| `postinst` | 配置时 | `post_install` / `post_upgrade` | `configure` |
| `prerm` | 移除前 | `pre_remove` | `remove` |
| `postrm` | 移除后 | `post_remove` | `remove` |

#### 5.5.1 为什么用 base64 内嵌

Debian 脚本里什么字符都可能有（单引号、反斜杠、`$`、heredoc）。
直接嵌入到生成的 bash 里必然要处理转义，而转义是 bug 温床。
base64 之后只剩 `A-Za-z0-9+/=`，**零转义风险**：

```bash
postinst_B64() { printf %s 'IyEvYmluL3No...'; }
```

#### 5.5.2 `_db_run` 包装函数

每个钩子都通过它执行：

```bash
_db_run() {
    local label="$1" b64="$2" action="$3" ver="$4"
    local d; d="$(mktemp -d)" || return 0
    printf '%s' "$b64" | base64 -d > "$d/s" || { rm -rf "$d"; return 0; }
    chmod 755 "$d/s"
    if [ -d /usr/local/lib/debinstall/shims ]; then
        export PATH="/usr/local/lib/debinstall/shims:$PATH"      # ← shim 生效点
    fi
    export DEBIAN_FRONTEND=noninteractive
    export DEBINSTALL_SCRIPTLET="$label"
    bash "$d/s" "$action" "$ver" >/dev/null 2>&1 || true         # ← 失败不阻断
    rm -rf "$d"
    return 0
}
```

设计要点：

- **临时目录执行**：不落固定路径，避免多包冲突和残留
- **`|| true`**：脚本失败不阻断安装。Debian 脚本在 Arch 上是"尽力而为"，
  它依赖的 `dpkg`、`update-alternatives`、AppArmor 都不存在，
  强制要求成功会让正常的包也装不上
- **输出丢弃**：`>/dev/null 2>&1`。这些脚本的输出对用户无意义，且会污染
  GUI 解析的 stdout 流
- **`DEBIAN_FRONTEND=noninteractive`**：防止脚本弹交互对话框卡死
- **`DEBINSTALL_SCRIPTLET`**：让 shim 知道是哪个脚本在跑（调试用）

#### 5.5.3 生成与否的判定

```bash
# 只统计真正会生成钩子的脚本
for f in preinst postinst; do [ -s "$ctl/$f" ] && any=1; done
if [ $RUN_REMOVE_HOOKS -eq 1 ]; then
    for f in prerm postrm; do [ -s "$ctl/$f" ] && any=1; done
fi
[ $any -eq 0 ] && return 1        # 没有脚本 → 不生成 .INSTALL
[ $RUN_SCRIPTLETS -eq 0 ] && return 1   # --no-scriptlet → 不生成
```

**注意 `any` 的统计不含移除阶段**（除非显式开启）——意味着一个只有 `prerm`
的包默认不会生成 `.INSTALL`。这是刻意的。

### 5.6 `update-alternatives` 模拟

#### 5.6.1 问题

Arch 没有 `update-alternatives`。而 Debian 包常靠它建立"通用命令名"：

```
# figlet 的 postinst 里
update-alternatives --install /usr/bin/figlet figlet /usr/bin/figlet-utf8 100
```

包里只有 `figlet-utf8`，`figlet` 这个通用名是链接出来的。
在 Arch 上跑这个 postinst 会失败，用户敲 `figlet` 得到"命令不存在"。

#### 5.6.2 解法：一个只做两件事的 shim

`_ALT_SHIM_B64` 里内嵌了一个 POSIX sh 脚本（base64）。

**为什么 base64 内嵌而不是单独一个文件？** 因为引擎是单文件分发的，
引外部文件会让"拷一个脚本到别的机器"失效。

**它只实现两个子命令：**

- `--install <link> <name> <target> [priority]` → 建链，并记台账
  （包括后续的 `--slave <link> <name> <target>` 组）
- `--remove <name> <target>` → 按目标路径删链

其余子命令（`--display`、`--config`、`--list`、`--query`、`--set`、`--get-selections`…）
**一律静默成功**。理由：postinst 里常有 `update-alternatives --display foo || true` 这类
探测调用，如果因为"命令不支持"而返回失败，可能中断整个安装流程。
静默成功最安全。

台账：`$DEBINSTALL_ALT_DB/links`（默认 `/var/lib/debinstall/alternatives`），
每行 `<名>\t<链接>\t<目标>`。

`write_shim(dir, cmd...)` 支持传前缀命令（`run_root`），这样才能写到需要 root 的
`SHIMDIR=/usr/local/lib/debinstall/shims`。shim 通过 `_db_run` 里那段
`export PATH="/usr/local/lib/debinstall/shims:$PATH"` 生效 —— **两处必须配套改**。

#### 5.6.3 shim 里的两个坑（写在注释里了，别重蹈）

**坑一：POSIX sh 里函数内的 `shift` 改不了调用方的 `$@`**

```sh
# 错：调用方的位置参数没变
_advance() { [ $# -gt 0 ] && shift; }
# 对：内联前移
[ $# -gt 0 ] && shift
```

**坑二：`grep -vF ... > tmp && mv tmp file` 在全部行被过滤时会跳过 mv**

```sh
# 错：所有行都匹配时 grep 返回 1，mv 不执行 → 链接删了但台账还在
grep -vF "$t" links > links.tmp && mv links.tmp links
# 对：
if grep -vF "$t" links > links.tmp; then
    mv -f links.tmp links
else
    : > links          # 全被过滤 → 台账清空
    rm -f links.tmp
fi
```

#### 5.6.4 本地模式的 alternatives 模拟（另一条路）

路线 B 不执行 `postinst`（它压根不生成 `.INSTALL`），所以 shim 不会跑。
于是 `emulate_alternatives_local` 直接**解析 postinst 源码**，把 `--install` 的
参数抽出来自己建链。

awk 逻辑（这个写起来比看起来微妙）：

```awk
{ buf = buf " " $0 }                    # ① 整个文件拼成一行，解决续行反斜杠
END {
    n0 = split(buf, raw, /[ \t]+/)
    m = 0
    for (i = 1; i <= n0; i++) {         # ② 滤掉空串和续行反斜杠
        if (raw[i] == "" || raw[i] == "\\") continue
        m++; c[m] = raw[i]
    }
    for (i = 1; i <= m; i++) {
        if (c[i] == "--install" && c[i-1] ~ /update-alternatives/) {
            if (c[i+1] != "" && c[i+3] != "") print c[i+1] "\t" c[i+3]
        }
    }
}
```

- ① 先合并所有行。否则 `update-alternatives --install \` 换行 ` /usr/bin/x ...`
  这种续行写法会漏掉
- ② 位置索引必须稳定：`--install <link> <name> <target> <priority>`
  → `i+1`=link，**`i+3`=target**（不是 i+2，i+2 是 name）
  续行的 `\` 如果不滤掉会占掉一个位置，导致取错

产出的链接：`~/.local/bin/<basename(link)>` → `<本地根>/<target>`。
只接受 `target` 以 `/usr/` 或 `/opt/` 开头（相对路径不可靠，跳过）。
如果 `~/.local/bin` 里已有一个**非符号链接**的同名文件，跳过不覆盖真程序。

### 5.7 本地安装（路线 B）的路径改写

本地安装把文件放在 `~/.local/debinst/<name>/`，但 `.desktop` 里的
`Exec=` 写的是 `/usr/bin/xxx`。不改写的话启动器点了没反应。

`rewrite_desktop` 处理四类键：

| 键 | 处理 |
|---|---|
| `Exec=` | 首个 token 若是绝对路径且 `<root><path>` 存在 → 改写成该路径；若是裸命令名且 `<root>/usr/bin/<name>` 或 `<root>/usr/games/<name>` 可执行 → 改写成该路径；否则原样保留 |
| `TryExec=` | 同上，但**找不到就整行丢弃**（留着会让启动器直接禁用这个项） |
| `Path=` | 同 `Exec=` 的规则 |
| `Icon=` | 绝对路径且存在 → 改写成本地路径；非路径（图标名）→ 原样保留 |

保留剩余参数（`%U`、`%F` 之类）：

```bash
read -r first rest <<<"$val"
printf '%s=%s%s\n' "$key" "$path" "${rest:+ $rest}"
```

#### 5.7.1 本地安装的固有局限（必须主动告知用户）

Debian 的包装脚本常按**绝对路径**调用同包的其它文件：

```sh
# figlet-utf8 内部
exec /usr/bin/figlet-figlet
```

本地模式下文件躺在 `~/.local/debinst/figlet/usr/bin/`，真实 `/usr/bin` 里没有。
**命令能点到，一跑就报「没有那个文件或目录」。**

`warn_local_abs_refs` 主动扫这类引用：

- 只扫脚本（前 2 字节是 `#!`），不扫二进制
- 扫 `dest/usr/bin`、`dest/usr/games`、`dest/usr/libexec`
- 用 `grep -ohE '/(usr|opt)/[A-Za-z0-9._+/-]+'` 抽绝对路径
- 抽到的路径在**本机**不存在 → 报告
- 有发现返回 1，调用方据此提示用户改用 `--install`

**这是"已知局限换主动检测"的典型例子**：不假装能解决，但绝不静默失败。

### 5.8 Debian 补库与兼容启动器（2.0.1 新增）

**要解决的问题**：只发 `.deb` 的国产客户端（网易邮箱大师 5.0.2.1011 是标本）
会链接 Arch 仓库里根本不存在的 soname。`--install` 全绿通过、pacman 也装成功，
**但点图标就是起不来**。实测两层：

| 类型 | 例子 | Arch 侧情况 |
|---|---|---|
| Debian 专属库 | `libnss_wrapper.so` | 全仓库（含 archlinuxcn）都没有，`pacman -F` 查不到 |
| 旧 soname | `libsasl2.so.2` | `libsasl` 只给 `.so` / `.so.3` |

**解法链**（`setup_compat_libs` → `fetch_debian_libs` → `make_compat_wrapper`）：

```
missing_sonames(root, COMPAT_DIR)          # ① 枚举 Arch 解析不了的 soname
  └─ resolve_sonames 过滤掉仓库能提供的
debian_pkg_for_soname <soname>             # ② 查 packages.debian.org 的 Contents 索引
  └─ 解析页面唯一那张 <table> 里 href="/<suite>/<pkg>"
debian_deb_url <pkg> <suite>               # ③ 查 download 页，抓 pool/… 相对路径
  └─ 统一挂 https://deb.debian.org/debian/  （官方 CDN，比抓到的随机镜像稳）
fetch_debian_libs                          # ④ dpkg-deb -x → 平铺 usr/lib/**/*.so* 到 COMPAT_DIR
  └─ 保留符号链接（只有 soname 名没有实体名会加载失败）
循环最多 3 轮                               # ⑤ 补进来的库可能又引出新缺失
make_compat_wrapper                        # ⑥ 生成启动器 + 用户级 .desktop
```

**六个设计决定，每个都有理由**：

1. **为什么从 Debian 取，而不是软链 Arch 上同名的其他版本**。
   `libsasl2.so.2` 可以软链到系统的 `.so.3`（ABI 2↔3 兼容），但那是赌；
   Debian 有现成的 `libsasl2-2` 包，直接取准确的版本。软链只作为无网络时的
   人工兜底写进 SKILL.md。

2. **为什么必须生成启动器**。`LD_LIBRARY_PATH` 得有人注入，而三条路都堵：
   改 `/opt` 里的文件会被 pacman 升级覆盖（且不在包清单里）；往 `/usr/lib`
   塞库要 root 且污染系统；`/etc/ld.so.conf.d` 同理。用户级 `.desktop`
   优先级高于 `/usr/share/applications`，正好用来挂启动器 —— **不碰 root 文件**。

3. **为什么要认出 `launch.sh` 这类包装脚本**。`Exec=/opt/mailmaster/launch.sh`
   里就是那个用 `lsb_release` 判断发行版的拦路虎，直接 exec 它等于没绕开。
   `make_compat_wrapper` 在同目录找与目录同名（`/opt/mailmaster` → `mailmaster`）
   或与 desktop 同名的可执行文件当替身。这是启发式，认不出来时明确警告。

4. **为什么应用专属修复要单独放 `.env`**。Qt5 GLX 在 Mesa 上段错误这类问题，
   工具**不可能通用地知道**。若把 `export QT_XCB_GL_INTEGRATION=none` 写进启动器，
   下次重新生成启动器就丢了。所以启动器 source
   `~/.config/debinstall/<app>.env`，且**已存在的 .env 绝不覆盖**。

5. **为什么用 `X-DebInstall-Wrapper=1` 标记自己的桌面入口**。用来和"用户自己
   定制过的"区分：重新生成时只覆盖带标记的（干净），不带标记的先备份再覆盖；
   `check_desktop_shadow` 也靠它判断"这个遮蔽是正常的还是需要提醒的"。

6. **循环 3 轮而不是 1 轮**。Debian 的 `libsasl2.so.2` 自己还依赖别的库，
   补进来后可能引出新的缺失。上限 3 轮防止异常情况下死循环。

**开关**：`--no-compat` 关掉整套（不动 `~/.local`）。

**接线位置有讲究**：`setup_compat_libs` 必须在 `make_desktop_shortcut` **之前**
调用 —— 否则桌面那份拿到的是未注入库的原始 `Exec`。回归检查里有专门一条
断言这个顺序（`awk` 抓两处的行号比较）。

---

## 6. 安全模型

### 6.1 威胁模型

`.deb` 的 4 个维护脚本（`preinst`/`postinst`/`prerm`/`postrm`）是**外来代码**，
安装/卸载时**以 root 执行**。恶意 `.deb` 写一句 `rm -rf /` 就能真的执行。

这是 **Debian 包格式本身的性质**，不是哪个工具的 bug，也无法在保持兼容的前提下消除。
能做的只有：让用户看清、让危险动作需要显式确认、缩小默认执行面。

### 6.2 三层防护

#### 第一层：默认只读

不带 `--install` / `-l` / `-x` 就绝不写系统。`--install` 内部也先跑完整分析。

#### 第二层：危险动作扫描 `DANGER_RE`

对 4 个脚本逐个 `grep -qE`，命中则置全局 `DANGER=1`
并打印**带行号的具体命中行**（`grep -n`），让人看到是哪一行。

正则的 9 条分支（实测：11 个危险样例全部命中，7 个正常样例零误报）：

| # | 模式 | 抓什么 |
|---|---|---|
| 1 | `rm\s+-[a-zA-Z]*[rR][a-zA-Z]*\s+(--\s+)?/(\s|$)` | `rm -rf /`（带不带 `--` 都抓） |
| 2 | `rm\s+-[rR][a-zA-Z]*\s+-[a-zA-Z]*\s+/(\s|$)` | `rm -r -f /`（参数分开写） |
| 3 | `dd\s[^\|]*of=/dev/` | 写块设备 |
| 4 | `mkfs\.` | 格式化 |
| 5 | `>\s*/dev/(sd\|nvme\|vd\|mmcblk)` | 重定向写块设备 |
| 6 | `(curl\|wget)[^\|]*\|\s*(ba\|z\|k)?sh` | 远程脚本直灌 shell |
| 7 | `chown\s+-R\s+\S+\s+/(\s\|$)` | 递归改根目录所有者 |
| 8 | `chmod\s+-R\s+[0-7]*777\s+/` | 递归 777 |
| 9 | `:\(\)\{\s*:\|:&` | fork 炸弹 |

设计取向：**宽进严出** —— 宁可偶尔误报让人多看一眼，也不能漏报。
但误报会伤体验，所以第 3、6 条都用 `[^|]` 而不是贪婪匹配，避免把
`dd if=/dev/zero of=/tmp/x`（正常）当成危险。

> 注意：这是**基于正则的启发式**，不是沙箱。能绕过的方式多得是
> （变量拼接 `R=/; rm -rf $R`、base64 解码后执行、编译时注入……）。
> **它只提高门槛，不提供保证。** 文档和 UI 文案都不要暗示它安全。

#### 第三层：非交互模式下的硬拒绝

```bash
if [ "$DANGER" -eq 1 ]; then
    if [ $ASSUME_YES -eq 0 ]; then
        if [ -t 0 ]; then
            printf '  确认信任并继续安装？输入 yes 才继续： '
            read -r a; [ "$a" = "yes" ] || die "已取消"
        elif [ $ALLOW_DANGER -eq 0 ]; then
            die "非交互模式下拒绝安装高危包（确认信任请加 --allow-dangerous）"
        fi
    fi
```

**`[ -t 0 ]` 这个判断是本工具踩过的最大的坑**，见 6.4。

### 6.3 为什么 `prerm` / `postrm` 默认不执行

`RUN_REMOVE_HOOKS=0` 是默认值。理由：

1. **卸载发生时，用户早忘了安装时看到的那份警告。** 安装时的危险扫描
   警告是一次的，几个月后 `pacman -R` 时会以 root 执行同一份代码，但这次**没有任何提示**。
2. **Debian 的移除脚本在 Arch 上基本都是空转。** 它们做的事（`update-alternatives --remove`、
   AppArmor profile 清理、systemd 单元 deregister）在 Arch 上都不存在或有别的机制。
3. **风险收益比极差。**

代价：`update-alternatives --remove` 不会执行 → shim 建的命令名链接可能残留。
但 shim 自己的台账在 `$ALT_DB/links` 里，可以手工清理。这是**刻意的取舍**。

要开启：`--run-remove-hooks`，此时分析阶段会打印醒目的橙色警告。

### 6.4 ⚠️ `[ -t 0 ]` 判不出"没人看着"

**关键认知：`stdin` 不是终端 ≠ 有人能回答问题。**

实测失败场景：测试脚本里 `echo n | debinstall --install demoapp.deb`。
`[ -t 0 ]` 为假 → 走进"非交互"分支 → 但当时的代码在那个分支里**什么都没做**，
直接往下执行安装。于是：

- 提示被静默跳过
- **`postinst` 真的执行了**（合成测试包里那个 `rm -rf /` 真的跑了，
  靠 coreutils 的 `--preserve-root` 才没出事）
- 事后通过 pacman 日志（`/var/log/pacman.log` 15:54:21）才发现包真被装进去了

**`[ -t 0 ]` 为假的三种情况都必须考虑：**

| 场景 | `[ -t 0 ]` | 有无人值守 |
|---|---|---|
| 终端里手动跑 | 真 | 有人在 |
| `echo n \| cmd`、`setsid cmd` | 假 | 无人 |
| GUI（`.desktop` `Terminal=false`） | 假 | 有人在（有窗口） |
| 脚本 / CI 调用 | 假 | 无人 |

第二、四种必须拒绝；第三种需要另一条提问通道（这就是 `deb-install-askpass` 的由来）。

**修法就是 6.2 第三层那段**：非 tty 且未显式加 `--allow-dangerous` → `die`。
GUI 因为知道自己在跑，会主动补上 `--allow-dangerous`（在用户看过警告对话框之后）。

> 任何新加的交互式确认都必须区分"能不能问"和"该不该自动通过"。
> **绝不能把"问不出来"当成"用户同意"。**

---

## 7. 引擎 ↔ GUI 接口契约　★ 改文案前必读

**GUI 通过解析引擎的 stdout 文本来工作。这不是一个好的设计，但它是现状，
所以必须当作契约来维护。**

### 7.1 分包规则

引擎往 stdout 写的内容，GUI 按行处理：

| 行首 | 含义 | GUI 行为 |
|---|---|---|
| `==>` | 段落标题 | 染成蓝色 info |
| `  ✓` | 通过 | 染绿 |
| `  !` | 警告 | 染橙 |
| `  ✗` | 失败/危险 | 染红 |

### 7.2 界面简化后仍在用的抓取正则（GUI 侧，逐字符敏感）

摘要卡片（依赖/脚本/冲突三行）已经随界面精简删掉了。现在 GUI 只抓两件事：

```python
RE_PKG = re.compile(r"^\s*包名\s+(\S+)")     # → 顶部标识行 + 「安装/更新」判断
RE_VER = re.compile(r"^\s*版本\s+(\S+)")     # → 顶部标识行
```

对应的引擎侧输出（`analyze_deb`）：

```bash
printf '  %s %s\n' "包名        " "$name"      # 注意：中文后面的空格数不重要
                                                # 但字段名后面的空白是分隔符，必须存在
```

`包名` 还多了一个下游用途：`_is_installed()` 拿它去问 `pacman -Q`，
以决定就绪态是「要安装此应用吗？」还是「要更新此应用吗？」。
**它的值必须是净化过的 Arch 包名**，否则更新态认不出来。

### 7.3 仍然被匹配的字面字符串

逐行日志现在都进"详细输出"折叠区，所以下面这些串**不再驱动卡片**，
但它们仍然是契约的一部分：要么被 GUI 匹配，要么被回归检查断言
（`test/run-checks.sh` §7 的 `proto_check`）：

| 引擎输出里必须包含 | 用途 |
|---|---|
| `高危` | **安全相关**：置 `self.dangerous = True`（见 7.4） |
| `包名` / `版本` | 标识行、安装/更新判断 |
| `没有安装脚本` | 回归断言：只读分析的脚本段落存在 |
| `所有动态库已满足` | 回归断言：依赖段落走完了 |
| `没有 desktop 遮蔽冲突` | 回归断言：冲突段落走完了 |

`analyze_deb` 里对应的 `printf` 必须**同时**带上 `✓`/`!`/`✗` 前缀（给日志染色用）
和上表里的字面串。比如：

```bash
ok "没有 desktop 遮蔽冲突"                    # → "  ✓ 没有 desktop 遮蔽冲突"
warn "$(basename "$d") 会遮蔽系统级同名文件..."  # → "  ! xxx.desktop 会遮蔽系统级..."
```

### 7.4 `self.dangerous` 是安全相关的状态传递

`_consume` 里：

```python
if "高危" in s:
    self.dangerous = True          # ← 这个标志决定安装时弹哪种对话框
```

`dangerous=True` 的效果（`_on_install`）：

1. 弹出 WARNING 类型对话框（不是普通的 QUESTION），文案点名高危动作
2. 用户确认后，往命令里**自动补 `--allow-dangerous`**

**所以「高危」这两个字同时承担了三件事**：日志染色、横幅提示、
安全门禁状态传递。改它等于同时改三处行为。

### 7.5 退出码契约

| 场景 | 退出码 | GUI 反应 |
|---|---|---|
| `analyze_deb` 正常结束 | 0 | 启用「安装」按钮 |
| 引擎 `die` | 1 | 保持禁用，提示"分析未通过" |
| `--install` 成功 | 0 | 提示安装完成 |
| `pacman` 失败 | 1（`exit 1`） | 提示安装未成功 |

> 注意：`analyze_deb` 自身**从不 `die`**（它只打印 `✗`/`!`）。
> 所以只要文件存在、引擎能找到，分析几乎总是返回 0，「安装」按钮总会亮。
> 真正的门禁在引擎内部（阶段 2）。这说明 GUI 的"分析未通过"这条路
> 实际上很少走到 —— 见第 9 章的设计债。

### 7.6 给后续开发者的建议

**应该把输出改成结构化格式。** 建议方案（列为第 9 章待办第 1 项）：

```bash
debinstall --json <pkg.deb>       # 输出一行一个 JSON 对象
```

GUI 优先解析 JSON，失败则回退到现在的文本匹配。这样两边可以独立演进，
且新增检查项不需要同时改两个仓库。

在做到这点之前，**改 `analyze_deb` 的任何输出前，先 `grep` 一下
`deb-install-ui` 里有没有人在匹配那个字符串。**

### 7.7 AppImage 分支：完全不经过引擎

`.AppImage` 由 GUI 自己处理（`deb-install-ui`），引擎一行代码都不参与。
原因：`debinstall` 的世界观是"拆包 → 审计脚本 → 解析依赖 → 转成 Arch 包"，
而 AppImage 是**自包含的单一二进制**，那三步一步都适用不上，
硬塞进引擎只会污染它的状态机（`MODE` 那一套）。

`self.kind` 只有两个值：`deb`（默认）和 `appimage`，在 `analyze()` 里按扩展名
分派，`_on_install()` 据此选路径。

**扫描（`_appimage_probe`）—— 只读，且这是硬要求：**

| 步骤 | 命令 | 说明 |
|---|---|---|
| 外壳 | `file -b` | 必须含 `ELF`；`shell script` → 判定为 type-1 并拒绝 |
| 架构 | 同上 | 与 `platform.machine()` 不符只告警，不阻断 |
| 目录 | `7z l -ba` | 列 6700 条目约 0.4 秒 |
| 元数据 | `7z e -y -so <pkg> usr/share/applications/*.desktop` | 抽到 stdout 解析，不落盘 |

> ⚠️ **绝不允许执行 AppImage 本体。** 输入是不可信的第三方二进制，
> 跑一次就等于让对方在你机器上任意执行。包路径只能作为**参数**
> 交给 `file` / `7z`，不能出现在 argv[0]。回归检查里有一条静态断言守着这点。

> ⚠️ **根目录的 `<name>.desktop` / `<name>.png` 是符号链接**（几十字节，
> 内容只有链接目标）。必须取 `usr/share/applications/` 和
> `usr/share/icons/hicolor/` 下的真身，否则抽出来的是两行文本。
> `7z l -ba` 的 attrs 列首字符是 `D`/`L` 的行（目录、符号链接）直接跳过。

**安装（`_install_appimage`）—— AppImageLauncher 式，全程不用 root：**

1. `mkdir -p ~/Applications`
2. `shutil.move` 把文件**移走**（原位置不再留东西），`chmod 0755`
3. 从**移动后的 dst**抽图标 → `~/.local/share/icons/hicolor/<尺寸>/apps/<slug>.<ext>`
4. 以包内 `.desktop` 为模板改写 `Exec`/`Icon` → `~/.local/share/applications/<slug>.desktop`
5. `update-desktop-database`（有 `kbuildsycoca6` 再补一刀），勾了快捷方式就再拷一份到 `$(xdg-user-dir DESKTOP)`
6. 写卸载清单 `~/.local/debinstall/appimages/<slug>.manifest`

第 3 步有个真踩过的坑：**移动之后原路径就不存在了**，图标抽取必须用 `dst`，
用 `path` 会得到"图标提取失败"但流程照样走完的静默缺陷。
回归检查 §7b 里有一条 `grep -qF 'f"-o{tmp}", dst'` 盯着。

**`slug` 是文件名，所以它是安全边界**：`slugify()` 只留 `[0-9A-Za-z_.+-]`，
空的或只剩 `.` 的退化成 `appimage`。取值的优先顺序是
`StartupWMClass` → 未本地化的 `Name` → 文件名主干 ——
用未本地化的名字，中文系统上才不会生出两个不同标识。

`Exec=` 用双引号包住整个路径，并对 `\ " $ ` ` 做反斜杠转义
（`_desktop_exec`）：文件名是外来输入，中文和空格都常见，直接拼会破。

**更新态判断**不看 `pacman`，看清单文件在不在（`_is_installed()` 按 `kind` 分派）。

**这条分支上没有等价的高危门禁**，因为根本没有脚本可审。补偿做法是在确认对话框里
明确告知"AppImage 不透明、无法审查、只有你能判断来源是否可信"，
日志里也固定打一条 `!` 说明审查边界。**别把这个告知删掉** ——
它是这条路径上唯一的风险披露。

---

## 8. 不变量与自检

这些是"破了就会静默出错"的地方。改动前后都要确认。

### 8.1 打包完整性（已有自检）

- 包内条目数 ≥ 源树条目数
- 包内有 `.PKGINFO` 和 `.MTREE`
- 违反则 `exit 1`，**绝不产出一个空包**

### 8.2 stdout 流不得污染

- **正常信息走 stdout，真错误走 stderr。** 理由写在源码注释里：
  GUI 把 stderr 并进 stdout 读（`stderr=subprocess.STDOUT`），
  而 stderr 是**块缓冲**的 —— 混进来会让整块内容在末尾一次性涌出，行序全乱。
- `_db_run` 里执行 .deb 脚本时**必须**重定向掉输出（`>/dev/null 2>&1`），
  否则外来脚本的 print 会插进 GUI 解析流。

### 8.3 `build_arch_pkg` 的最后一行必须是包路径

原因见 4.1。调用方用 `| tail -1`。

### 8.4 每处 `.PKGINFO` 的 `depend=` 必须经过 `in_repo` 过滤

写进 `.PKGINFO` 的依赖如果 Arch 仓库里没有，pacman 会直接拒绝安装整个包。
比"少一个依赖"糟糕得多。

### 8.5 shim 路径两处必须一致

`SHIMDIR=/usr/local/lib/debinstall/shims` 同时出现在：

1. `write_shim "$SHIMDIR" run_root`（写入点）
2. `_db_run` 里的 `export PATH="/usr/local/lib/debinstall/shims:$PATH"`（使用点）

改了一处必须改另一处（且 `_db_run` 那段是嵌在 heredoc 里的字符串，
grep 时容易漏）。

### 8.6 `trap cleanup EXIT INT TERM` 必须保留

`WORK` 是 `mktemp -d` 出来的。没有 trap，中断一次就在 `/tmp` 留一份解包树
（有的大包上 GB）。

### 8.7 `set -uo pipefail` 已开启

- `set -u`：未定义变量会报错。所以**新加的变量务必先初始化**。
  数组尤其注意：`"${arr[@]}"` 在空数组上，bash 5 是安全的，但写法上
  优先用 `"${arr[@]:-}"` 或先判长度（代码里两种都有）
- `pipefail`：管道中任一环失败即整体失败。这让
  `elf_sonames ... | grep -vxF ...` 这类管道需要 `|| true` 收尾 —— 代码里已这么做

### 8.8 补库必须先于桌面快捷方式（2.0.1）

`do_install` 里的顺序不能改：

```bash
setup_compat_libs "$croot"    # 先生成带 wrapper 的用户级 .desktop
[ $MAKE_DESKTOP -eq 1 ] && make_desktop_shortcut   # 再据此铺桌面快捷方式
```

反过来的后果：`make_desktop_shortcut` 会优先挑带 `X-DebInstall-Wrapper=1` 的
用户级那份，此时它还不存在，于是桌面拿到原始的 `Exec`（没注入 `LD_LIBRARY_PATH`），
**应用从桌面点还是起不来，但从菜单点能起来** —— 这种"一半能用"最难排查。
回归检查用 `awk` 抓两处行号比较顺序。

### 8.9 目录权限规范化不能被绕过（2.0.1）

打包前必定执行 `find "$root" -type d -exec chmod go-w {} +`（除非显式设了
`DEBINSTALL_KEEP_DIR_PERM`）。**只动目录、不动文件** —— 有些包确实需要文件
带特殊位（SUID 之类），改文件权限会破坏它们。

漏掉这一步的后果不是报错，而是两件静默的事：
- pacman 对着已存在的 `/opt`、`/usr/share` 报「目录权限不一致」警告；
- 包新建的 `/opt/<app>` 变成 `drwxrwxr-x`，组内可写 → 组里有人就能替换
  应用二进制。默认组成员是 `root`，但用户一旦被加进 root 组就真成提权面了。

---

## 9. 已知缺陷与设计债

按建议处理优先级排序。

### 9.1 `analyze_deb` 从不失败 → GUI 的"分析未通过"形同虚设

**现状**：`analyze_deb` 只打印结果，从不 `die`。所以 GUI 的
`done(rc)` 里 `rc == 0` 分支几乎总能走到，「安装」按钮总会亮。
用户即使看到红色的"缺失库"，按钮也是可点的。

**影响**：门禁实际上只剩引擎内部那一层，GUI 层没有把关。

**建议**：加 `--strict` 模式，在"缺库 / 高危"时返回非 0；
或（更好）先做 9.2 的 JSON 输出，让 GUI 按结构化字段决定按钮状态。

### 9.2 文本协议脆弱（第 7 章）

**现状**：GUI 靠 8 个中文字面串匹配。

**建议**：加 `--json`。这是**对后续开发影响最大的一个改动**，建议优先做。

### 9.3 未校验 pacman 文件数据库是否存在

**现状**：依赖解析完全建立在 `pacman -F` 可用之上。而 `pacman -F`
要求文件数据库 `*.files` 已下载（由 `pacman -Fy` 生成，不是默认就有）。

**影响**：如果用户从没跑过 `pacman -Fy`，`pacman -F` 失败
→ `resolve_sonames` 拿到空输入/空输出 → **解析不出任何依赖** →
装出来的包 `depend=` 为空 → 安装成功但运行时缺库。
**失败是静默的，这是最危险的一点。**

**建议**：在 `build_arch_pkg` 开头加检查：

```bash
ls /var/lib/pacman/sync/*.files >/dev/null 2>&1 || {
    warn "pacman 文件数据库不存在，依赖解析会失败。先执行：sudo pacman -Fy"
}
```

更稳的做法是解析失败（有 soname 但零映射）时直接告警而非静默继续。

### 9.4 `format` 参数从未被使用

`rewrite_desktop(src, root, man)` 的第三个参数 `man` 在函数体内没有任何引用。
调用处传的是 manifest 路径（看得出原本想往里写记录，后来改成由调用方处理）。

**建议**：删掉该参数，或补上「记录被改写的文件」的行为。

### 9.5 两个孤儿脚本

`deb-install-open` 和 `deb-install-raw` 无人调用（见 3.1）。

- `deb-install-open`：原本是终端双击方案，被 GUI 取代。保留价值：无 GUI 环境
- `deb-install-raw`：路线 C，是三路线里唯一的兜底。**建议保留，但接进流程**

**建议**：
- 给 `deb-install-raw` 在 `debinstall` 里加一条 `--raw` 转发（或在
  `do_install` 失败提示里明确写出它的用法）
- `deb-install-open`：要么删，要么做一个"终端模式"的 desktop 变体

### 9.6 `.deb` 被解包两次

`MODE=install` 的执行序列是：`analyze_deb`（自己 `mktemp -d` 解包一次，
用完 `rm -rf`）→ `do_install` → `build_arch_pkg`（在 `WORK` 里再解包一次）。

**影响**：大包上多花几秒和一份磁盘 IO。功能正确。

**建议**：让 `analyze_deb` 接受一个可选的"复用已解包目录"参数。

> 补记（2.0.1）：`setup_compat_libs` 需要一棵解开的树，**必须复用
> `build_arch_pkg` 留下的 `$WORK/root`**，不要再解第三次 —— 网易邮箱大师那种
> 217MB 的包，多解一次就是几百 MB 的写放大。回归检查里有专门一条断言
> `local croot="$WORK/root"` 存在。

### 9.7 `fix_electron` 的时间窗口是硬编码 3 分钟

```bash
sb=$(find /opt /usr/lib -maxdepth 4 -name chrome-sandbox -newermt '-3 minutes' ...)
```

如果这次安装耗时超过 3 分钟（大包 + 慢盘完全可能），就找不到刚装的
`chrome-sandbox`，权限不会被修，Electron 应用启动报沙箱错误。

**建议**：改成从包清单里精确定位，而不是靠时间窗口猜。
（`analyze` 阶段已经知道包里有哪些文件了。）

### 9.8 `du -sb --exclude=` 的三个 exclude 是空转

```bash
size=$(du -sb --exclude='.PKGINFO' --exclude='.INSTALL' --exclude='.MTREE' "$root" | cut -f1)
```

这行**在 `.PKGINFO` 写入之前**执行，`.INSTALL` 和 `.MTREE` 也还不存在。
所以三个 exclude 实际不生效（无害，只是误导读者）。

**建议**：要么删掉 exclude（并注释说明此时元数据文件尚未生成），
要么把 `size` 的计算挪到所有元数据写完之后。

### 9.9 `size` 字段含目录大小

`du -sb` 把目录自身也计入。pacman 的 `size` 语义是"安装后占用"，
一般用 `du` 是常见做法，但严格说 `pacman -Qi` 显示的体积会略偏大。

**优先级低**，除非有人拿这个数字做磁盘规划。

---

## 10. 扩展点：往哪加东西
### 10.1 加一条 Debian→Arch 依赖映射

`BUILTIN_MAP` heredoc，格式 `Debian名<TAB>或空格<Arch名>`，一行一条。
**注意**：这里写的是 `awk '$1 == n { print $2 }'`，所以是**空白分隔**，不是制表符。
当前用的是空格对齐。

### 10.2 加一个危险模式

改 `DANGER_RE`，用 `|` 追加分支。**必须遵守的约定**：

- 用 `[[:space:]]` 而不是 `\s`（POSIX ERE 里 `\s` 不可靠）
- 尾部锚 `(\s|$)` 防止把 `/a/b` 误伤成 `/` 的匹配
- 用 `[^|]` 限制跨管道匹配，避免把正常的 `cmd > /dev/null` 类语句卷进来
- **加完必须跑一遍正反样例**（见 HANDOFF.md 的正则测试方法）

### 10.3 加一个模式

1. 参数解析里加分支，设 `MODE=xxx`
2. 文件头部的 `MODE=` 注释里补上新值（现在列了 7 个）
3. 主 `case "$MODE" in` 底部加分支
4. 如果新模式需要 `WORK`，记得 `WORK=$(mktemp -d ...)`
5. 如果新模式需要 root，先调 `detect_escalation` 再用 `run_root`
6. 在 `usage()` 里补文档 —— **注意 `usage()` 用的是固定行号
   `sed -n '3,16p'`**，改头部注释会移动行号。⚠️ 当前 `usage()` 用的是
   `cat <<'EOF'` heredoc（不是 sed），改注释不影响；但
   `deb-install-raw` 里用的是 `sed -n '3,13p' "$0"`，那个会被移动行号影响

### 10.4 支持另一个发行版（比如 Fedora 的 `.rpm`）

不建议在 `debinstall` 里加分支 —— 逻辑差异太大（rpm 有自己的依赖模型、
脚本命名 `%pre`/`%post`、没有 alternatives 概念）。**另写一个引擎**，
复用这几部分思路：

- 「默认只读 + 显式确认」的交互框架
- 「转成原生包交给原生包管理器」的核心主张
- 危险脚本扫描（正则基本可复用）

### 10.5 加 GUI 语言

GUI 是硬编码中文（`APP_TITLE = "软件包安装程序"`，CSS 里的 .desktop 有
`Name[en]`）。没有 gettext。如果要国际化，建议先把
第 7 章那些字面串匹配干掉（改成 JSON），否则字符串既是 UI 文案又是协议。

---

## 附：快速事实卡

```
引擎版本        2.0.1
模式数          7（analyze/install/local/extract/convert/list-local/uninstall-local）
必需外部命令    dpkg-deb(→dpkg) bsdtar(→libarchive) fakeroot zstd pacman
                readelf, ar(→binutils，仅路线 C)
GUI 依赖        python3 + PyGObject + GTK3；shebang 必须 /usr/bin/python3
shim 路径       /usr/local/lib/debinstall/shims/update-alternatives
shim 台账       /var/lib/debinstall/alternatives/links
本地安装根      ${DEBINSTALL_LOCAL_ROOT:-~/.local/debinst}/<包名>/
本地台账        <本地安装根>/.debinstall-manifest（一行一个路径）
本地元信息      <本地安装根>/.debinstall-info
兼容库目录      ${DEBINSTALL_COMPAT_DIR:-~/.local/lib/debcompat}/（Debian 补来的 .so*）
应用专属修复    ${DEBINSTALL_COMPAT_ENV:-~/.config/debinstall}/<app>.env（启动器 source 它）
兼容启动器      ~/.local/bin/<desktop名>（带 "debinstall 兼容启动器" 标记）
补库上游        packages.debian.org（Contents 索引 → download 页 → deb.debian.org）
路线 C 台账     /var/lib/deb-install/<包名>.list 和 .meta
临时工作目录    /tmp/debinstall.XXXXXX（trap 清理）
```
