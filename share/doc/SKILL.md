---
name: arch-install-deb
description: 在 Arch Linux 上安装 .deb 包（Debian/Ubuntu 格式的应用）。当用户说「安装/更新某个 deb 包」「装一下这个 .deb」「软件只有 deb 版」时使用。本机已装成套工具 debinstall / deb-install-ui / deb-install-raw，覆盖两条路线（转 Arch 包交给 pacman 跟踪、或铺开到 / 并记台账），并含高危脚本审计、ELF→pacman -F 依赖解析、GUI 提权、Electron 四个必踩坑（ELECTRON_RUN_AS_NODE 污染、desktop 遮蔽、单实例锁、chrome-sandbox 权限）。
agent_created: true
---

# Arch Linux 安装 .deb 包

> **优先用配套工具**（本机已装，见下方「装 .deb 优先用现成工具」一节）：
> - `~/.local/bin/debinstall <pkg.deb>` — 命令行主力。默认只读体检，
>   `--install` 才写系统；另支持 `-l`（装到 ~/.local，免 root）、`-c`（只转包）、
>   `-x`（只解包）、`--no-desktop`、`--no-compat`、`--allow-dangerous`、
>   `--run-remove-hooks`
> - `~/.local/bin/deb-install-ui <pkg.deb>` — **图形界面**（GTK3），`.deb` 双击默认走它
> - `~/.local/bin/deb-install-raw <pkg.deb>` — 旧的「铺开式」兜底，pacman -U 被文件冲突卡住时用
> - `~/.local/bin/deb-install-open <pkg.deb>` — 终端交互版（UI 不可用时的降级入口）
>
> 下面的手工步骤用于工具没覆盖到的情况，也是它的实现依据。

## 图形界面选型（Arch + KDE 实测结论）

**不要用 tkinter。** 实测两种死法：
1. WorkBuddy 自带的 python（Tk 9.0）字体后端缺失，`tkfont.families()` 只返回
   `['fixed']`，**中文字符被测量为 0 宽度**（"包名" reqwidth=4 而 "VERSION"=46），
   标签会被挤成不可见；
2. 系统 python3 常常没有 `libtk8.6.so`（`tk` 包未装），`import tkinter` 直接报错。

**用 GTK3 + PyGObject**（`gi` 模块通常随 `python-gobject` 就位，GTK 走 Pango，中文正常）：

```python
#!/usr/bin/python3           # ← 必须写死绝对路径
import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, GLib, Gtk
```

三个必踩点：
- **shebang 用 `#!/usr/bin/python3`**，不能用 `#!/usr/bin/env python3` —— 后者可能
  解析到没装 `gi` 的 python（如 WorkBuddy 自带的那个）
- `Gdk.RGBA().parse("#rrggbb")` 是**原地修改并返回 bool**，不是返回对象；
  换颜色用 CSS class（`override_color` 在 GTK 3.24 已废弃会报警告）
- 子线程跑 `subprocess` 读输出，用 `GLib.idle_add()` 回主线程刷 UI；别在子线程碰控件

**排版教训**：`Gtk.Box` + `pack_start(child, expand, fill, 0)` 要成对设置；
摘要行用「标签 `set_size_request(56, -1)` + 值 `expand=True`」最稳。
tkinter 时代 `pack(side="left")` 把标签挤没的问题在 GTK 里不存在。

## 图形界面提权：GUI 里 sudo 问不出密码（必踩）

`deb-install.desktop` 是 `Terminal=false`，所以从 GUI 起来的 `deb-install` **没有控制终端**。
此时 `sudo` 拿不到 tty 就**既不弹密码框也不报错，直接静默挂死**——表现是点了"安装"之后
进度条一直转，什么也不发生。WorkBuddy 之类的环境里如果脚本被 `setsid`/无 tty 拉起，
命令行调用也会踩到同一个坑。

Arch 默认**不装任何图形 askpass**（`ksshaskpass` / `x11-ssh-askpass` 都要手动装），
所以别指望系统自带。正解是自己提供一个 GTK askpass + `sudo -A`：

```bash
# deb-install 里的提权判定（放在参数解析之前）
if [ -t 0 ]; then
    SUDO=(sudo)                       # 终端里跑，正常问密码
else
    if [ -z "${SUDO_ASKPASS:-}" ] && [ -x "$HOME/.local/bin/deb-install-askpass" ]; then
        SUDO_ASKPASS="$HOME/.local/bin/deb-install-askpass"
        export SUDO_ASKPASS
    fi
    if [ -n "${SUDO_ASKPASS:-}" ] && [ -x "$SUDO_ASKPASS" ]; then
        SUDO=(sudo -A)                # 图形 askpass 弹窗
    else
        SUDO=(sudo)
    fi
fi
```

之后**所有**提权点统一写成 `"${SUDO[@]}" cmd`，包括 `-v`：

```bash
"${SUDO[@]}" -v || die "需要 sudo 权限"
"${SUDO[@]}" tar -xf "$DATA" -C /
echo "$DEST" | "${SUDO[@]}" tee -a "$LEDGER/$PKGNAME.list" >/dev/null
```

> 用脚本批量替换 `sudo ` → `"${SUDO[@]}" ` 时注意：正则会把**注释和 echo 文案里的
> `sudo`** 一起改掉，事后要手工修回（本次踩了 4 处）。

askpass 脚本（`~/.local/bin/deb-install-askpass`，GTK3）要点：

- sudo 把提示语作为 **argv[1]** 传进来，把用户输入**原样打到 stdout**（多一个换行不影响）
- 取消时 `exit 1`，sudo 会当作空密码继续重试 → 配合 `sudo -k` 可快速失败而不是挂起
- `Gtk.Button.set_can_default(True)` 才 `set_default()`，否则报
  `gtk_window_set_default: assertion 'gtk_widget_get_can_default' failed`
- 收尾加 `win.present()`，否则窗口可能被其它窗口压在下面看不见

验证手法（不需要真人输密码）：

```bash
sudo -k
printf '#!/bin/sh\necho wrongpass\n' > /tmp/fakeask.sh && chmod +x /tmp/fakeask.sh
# 无 tty + 假 askpass：应当在 2 秒内以非 0 退出，而不是超时挂住
timeout 20 setsid env SUDO_ASKPASS=/tmp/fakeask.sh sudo -A -v </dev/null; echo "exit=$?"
```

程序化断言弹窗真的渲染出来了（不依赖截图肉眼判断）：

```python
import importlib.machinery, importlib.util, gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, GLib
loader = importlib.machinery.SourceFileLoader("ap", "/home/spiritherb/.local/bin/deb-install-askpass")
spec = importlib.util.spec_from_loader("ap", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)   # 文件无 .py 后缀，spec_from_file_location 会返回 None
a = m.AskPass("[sudo] 密码：")
GLib.timeout_add(800, lambda: (print("mapped:", a.win.get_mapped()), a._on_cancel(None), False)[2])
a.run()
```

## 安装后建桌面快捷方式

`deb-install --install` 默认建，`--no-desktop` 关闭（UI 底部有复选框）。

```bash
DESKTOP_DIR=$(xdg-user-dir DESKTOP)          # 别硬编码 ~/Desktop
LABEL=$(awk -F= '/^Name\[zh_CN\]=/{print $2; exit}' "$SRC")   # 中文名优先
cp -f "$SRC" "$DESKTOP_DIR/$LABEL.desktop" && chmod +x "$DEST"
```

**KDE 只需要 `chmod +x`**，不需要 `gio set metadata::trusted`（对比过现有的
微信/HMCL 桌面快捷方式，都没有 trusted 属性）。

⚠️ **卸载要连带清理**：桌面快捷方式和 `/usr/bin` 符号链接是脚本自己创建的、
**不在 deb 的 data 清单里**，必须显式追加进台账，否则卸载后会残留。
删除时用 `[ -e "$p" ] || [ -L "$p" ]` 判断（`-e` 对断链符号链接返回 false），
再 `rmdir` 清理 `/opt` 下变空的目录。


Arch 没有 dpkg。两条路线，先判断走哪条。

## 装 .deb 优先用现成工具，别手搓（本机已装）

本机 `~/.local/bin/` 里有一套成熟的工具，**遇到 .deb 先用它，不要重新写脚本**：

| 命令 | 作用 |
|------|------|
| `debinstall <pkg.deb>` | 默认**只读体检**：依赖解析、脚本审计、写入路径、冲突检测 |
| `debinstall --install <pkg.deb>` | 体检之后真正安装（转成 Arch 包交给 pacman）。装完自动补 Debian 专属库 + 生成兼容启动器，见下文「Debian 专属应用」 |
| `debinstall -l <pkg.deb>` | 解包到 `~/.local`，**不需要 root** |
| `debinstall -c <pkg.deb>` | 只生成 Arch 包不安装 |
| `deb-install-raw <pkg.deb>` | 旧的「铺开式」兜底：直接 `sudo tar -xf` 到 `/` |
| `deb-install-ui` | GTK3 图形界面（双击 .deb 就起它） |

**两条路线的取舍** —— 这是本机最有价值的一条经验：

- **`debinstall`（转 Arch 包 + `pacman -U`）**：装完被 pacman 完整跟踪，
  `-R` / `-Qo` / `-Ql` / `-Qk` 全可用。**代价**：pacman 遇到文件冲突会拒绝安装，
  而 Electron 应用自带一堆系统已有的库，很容易卡住。
- **`deb-install-raw`（`sudo tar -xf` 铺开）**：不管冲突硬铺，什么都能装上。
  **代价**：pacman 数据库里没有任何记录，`pacman -Qo` 会说「不属于任何包」，
  卸载只能靠它自己记的台账。
- 所以顺序是：先 `debinstall --install`，**被文件冲突卡住时才退到 `deb-install-raw`**。

### 三个安全设计（踩过坑才加上去的，别当成啰嗦）

1. **默认只读**。`.deb` 自带的 `postinst` 是外来脚本，安装后会**以 root 执行**。
   所以默认不动系统，看清楚再 `--install`。
2. **高危脚本审计**。扫 `rm -rf /`、`dd of=/dev/sd*`、`mkfs.`、
   `curl | sh`、`chown -R ... /` 等模式。
   **实测教训**：用合成包验证时，带 `rm -rf /` 的 postinst **真的被执行了**
   （被 coreutils 的 `--preserve-root` 拦下才没出事）。
   更坑的是 prerm 里的 `dd if=/dev/zero of=/dev/sda` —— 它会在**卸载**时触发，
   那时你早忘了安装时的警告。所以现在：
   - 非交互模式（管道 / GUI）遇到高危包**直接拒绝**，必须显式 `--allow-dangerous`
   - **卸载阶段钩子默认不生成**，要执行得加 `--run-remove-hooks`
   - 清理这种测试包前，先把 `/var/lib/pacman/local/<pkg>/install` 置空再 `pacman -R`，
     否则卸载动作本身就是一次踩雷
3. **依赖解析走 ELF 而不是字面翻译**。扫包内**全部** ELF 的 `DT_NEEDED`，
   再用 `pacman -F` 反查真正提供该 soname 的 Arch 包（core > extra > multilib 优先级）。
   比维护一张 Debian 名 → Arch 名的对照表准得多 —— 后者只能覆盖几十个常见包。

### 常见误判：`[ -t 0 ]` 判不出「没人看着」

```bash
echo n | ./debinstall --install xxx.deb     # 提示被跳过，直接开始安装！
script -qec 'echo n | test -t 0' /dev/null  # → NOTTY
```

管道、`setsid`、GUI 拉起的进程 stdin 都不是 tty，`[ -t 0 ]` 为假，
基于它的交互确认会被**静默跳过**。凡是「要不要继续」的闸门，
必须对「非交互」这个分支单独给一个安全默认值，不能直接放行。

### `update-alternatives` 必须自己补（否则命令名会消失）

Debian 包常用 `update-alternatives` 把「通用命令名」指向带后缀的真身。
最典型的例子就是 **figlet**：包里只有 `/usr/bin/figlet-utf8` 和 `figlet-figlet`，
`/usr/bin/figlet` 是 postinst 用 alternatives 链接出来的。
Arch 上没有这个命令，**不补的话装完敲 `figlet` 就是找不到命令**，而包本身没坏。

工具里两条路都补了：

- **系统安装**：把一个小 shim 写到 `/usr/local/lib/debinstall/shims/update-alternatives`，
  `.INSTALL` 钩子执行时把该目录前置进 PATH。shim 只实现 `--install` 建链 /
  `--remove` 删链，其余子命令静默返回 0（免得 postinst 因「命令不存在」中断）。
- **本地安装**（不跑 postinst）：用 awk 扫 postinst 里的
  `update-alternatives --install <链接> <名> <目标> <优先级>`，把链接建到 `~/.local/bin`。

写这个 shim 踩到三个坑，都值得记住：

```sh
# 坑 1：`grep -vF ... > tmp && mv tmp file` 不可靠！
# 所有行都被过滤掉时 grep 返回 1，&& 后面的 mv 不执行 →
# 链接删了、台账还在。要 `|| true`，或判断后显式清空。
# 坑 2：函数内 shift 动不了调用方的 $@（POSIX sh）。
# 想让参数前移只能内联 `[ $# -gt 0 ] && shift`。
# 坑 3：postinst 里的续行反斜杠会成为一个独立 token，
# 干扰「--install 后面第 3 个就是目标」的位置假设。
# 必须先把 token 列表里的空串和 "\" 全滤掉再取位置。
```

### 本地安装的固有局限（要主动告知用户）

`-l` 装到 `~/.local` 时，Debian 的**包装脚本**会失效 —— 它们常按绝对路径
调用同包的其它文件，例如 figlet 的 `/usr/bin/figlet-utf8` 里就有：

```sh
exec /usr/bin/figlet-figlet "$@"
```

本地安装后文件在 `~/.local/debinst/figlet/usr/bin/`，`/usr/bin/figlet-figlet` 不存在，
于是「命令能点到、一跑就报错」。工具现在会扫出来并提示改用系统安装。
**遇到这种包就走 `--install`，别在本地模式上硬耗。**

### 性能：`pacman -F` 一定要批量调用

逐个 soname 调一次 `pacman -F` 会慢到不可用 —— 实测 **4 个库 33.7 秒**；
批量一次传全部 soname 只要 **9.2 秒**，一个 14 依赖的包从 **2 分钟降到 15 秒**。
同理 `in_repo` 别逐个 `pacman -Ssq` 反查，改成一次 `pacman -Slq` 拿全量包名再本地比对。

```bash
pacman -F libc.so.6 libX11.so.6 ...        # 一次
pacman -Slq | sort -u                       # 全量包名，缓存起来
```

解析时只认 `usr/lib/` 和 `usr/lib32/`，**跳过 `usr/lib64/`** ——
否则会把 aarch64/riscv64 交叉工具链里的同名库算成依赖（实测 glibc 会因此
匹配到 5 个以上无关包）。

## 路线选择（先做这一步）

```bash
# 1. 玲珑仓库里有这个应用吗？
export XDG_RUNTIME_DIR=/run/user/1000
ll-cli list | grep -i <关键词>          # 已装的
ll-cli search <关键词>                   # 仓库里的
ll-cli info <完整id>                     # 看仓库版本

# 2. 检查工具
for t in ll-cli ll-pica ll-builder ar tar makepkg; do printf "%-12s " $t; command -v $t || echo "—"; done
```

- **玲珑仓库有目标版本** → `ll-cli update <id>`，最省事
- **仓库版本旧 / 没有** → 走下面的原生路线
- ⚠️ **`ll-cli install` 只接受 `.uab` 和 `.layer`，不接受 `.deb`**，别指望它转换 deb
  （想转换需要 `ll-pica`，Arch 上通常要自己装）

## 原生安装（仓库版本落后时的正解）

**先确认宿主依赖齐全**（Electron 应用常见清单）：

```bash
for lib in libgtk-3.so.0 libnss3.so libXss.so.1 libXtst.so.6 \
           libatspi.so.0 libsecret-1.so.0 libnotify.so.4 libnspr4.so; do
  ldconfig -p | grep -q "$lib" && echo "✓ $lib" || echo "✗ $lib"
done
```

Arch 上对应的包名（和 deb 里写的 Debian 名不同，别被误导）：
`gtk3` / `nss` / `libxss` / `libxtst` / `at-spi2-core` / `libsecret` / `libnotify`

依赖齐了就安装：

```bash
cd /tmp && mkdir -p work && cd work
ar x ~/Downloads/<pkg>.deb                 # 拆出 control.tar.xz + data.tar.xz
tar -xf control.tar.xz -C ctl 2>/dev/null  # 先审计 postinst/postrm！
cat ctl/control                            # 看 Package/Version/Depends

# deb 的 data 布局就是文件系统布局，直接铺开
sudo tar -xf data.tar.xz -C /

# 建立入口
sudo ln -sf '/opt/<AppDir>/<binary>' /usr/bin/<binary>
sudo chmod 0755 '/opt/<AppDir>/chrome-sandbox'   # 有 user namespace 时；否则 4755

# 刷新数据库
sudo update-desktop-database /usr/share/applications
sudo gtk-update-icon-cache -f -t /usr/share/icons/hicolor
```

**安装前务必先读 `postinst`/`postrm`** —— deb 的安装脚本会做系统级操作
（`update-alternatives`、装 AppArmor profile 等）。Arch 上这些多半会被跳过，
但看一眼能确认没有意外行为。

## 四个必踩的坑

### 坑 1：`ELECTRON_RUN_AS_NODE=1` 污染 —— 最容易浪费一小时

**WorkBuddy 的执行环境会注入这个变量。** 它让 Electron 二进制退化成纯 Node 解释器：

| 现象 | 说明 |
|---|---|
| `--help` 打印 **Node.js 帮助**（`Usage: node [options]...`） | 不是 Chromium 帮助 |
| `--version` 打印 `v22.x.x` | 是 Node 版本，不是应用版本 |
| 传任何 Chromium 参数 → `bad option: --xxx` | 参数被 Node 解析 |
| 启动后立刻静默退出 | Node 解不了 Electron 的包 |

**测任何 Electron 应用都必须：**
```bash
env -u ELECTRON_RUN_AS_NODE <应用路径> [args]
```

这只影响脚本环境，**用户从桌面启动不受影响** —— 别因为这个误判"装坏了"。

### 坑 2：用户级 desktop 遮蔽系统级

`~/.local/share/applications/xxx.desktop` **优先级高于** `/usr/share/applications/`。
如果之前用玲珑装过（desktop 里是 `Exec=/usr/bin/ll-cli run ...`），不移走的话
点图标还是启动旧版。

```bash
cd ~/.local/share/applications
mv xxx.desktop xxx.desktop.bak_linglong       # 先备份再移走
```

### 坑 3：单实例锁

Electron 应用的单实例锁按 **userData 目录**判定。新旧版本共用同一个
（如 `~/.config/moekoemusic`）时，旧实例活着 → **新版启动后立刻静默退出，日志为空**。

```bash
# 找出正在跑的是哪一版
ps -eo pid,etime,args | grep -F "<binary>"
sudo readlink /proc/<pid>/exe      # 指向 /opt/apps/<id>/... 就是玲珑版
# 关掉旧实例再启新版
kill <pid>
```

**好消息**：userData 共用意味着**切换无损**，歌单/设置/Cookies 都保留。
安装前 `ls -la ~/.config/<app>/` 确认一下。

### 坑 4：chrome-sandbox 权限

```bash
if [[ -L /proc/self/ns/user ]] && unshare --user true 2>/dev/null; then
  sudo chmod 0755 '/opt/<AppDir>/chrome-sandbox'   # 有 user namespace
else
  sudo chmod 4755 '/opt/<AppDir>/chrome-sandbox'   # 回退 SUID
fi
```

## Debian 专属应用：三层坑与「兼容启动器」（网易邮箱大师实例）

有些国产 Linux 客户端（网易邮箱大师 5.0.2.1011 是典型）只发 `.deb`，且自带
发行版检查 + Debian 专属依赖 + 2023 年编译的 Qt5。硬铺装完后**三重坑依次暴露**，
每一层都得单独处理。

> **前两层现在已由 `debinstall --install` 自动处理**（2.0.0+）：
> 装完自动从 Debian 取缺失的库到 `~/.local/lib/debcompat/`，并生成兼容启动器 +
> 用户级桌面入口把 `LD_LIBRARY_PATH` 注入进去。只有**第三层（应用专属的运行时
> 开关）必须人工判断**，写进 `~/.config/debinstall/<app>.env` 即可，重新生成
> 启动器时不会被冲掉。
> 关掉这套自动化：`--no-compat`。

**三层坑与对应解法**（实测顺序即暴露顺序）：

1. **启动脚本的发行版硬检查**
   ```bash
   # /opt/mailmaster/launch.sh 开头就是：
   RID=$(lsb_release -i | tr '[:upper:]' '[:lower:]')   # Arch 无此命令 → 空
   VER=$(lsb_release -r | tr '[:upper:]' '[:lower:]')
   if [ "$VER" \< "22.04" ] || [ "$RID" != "ubuntu" ]; then zenity --info ...
   ```
   注意 **zenity 报「系统版本低于 Ubuntu 22.04」是个幌子** —— 真实原因是 Arch 上
   根本没有 `lsb_release` 这个命令（Debian 的 `lsb-release` 包，Arch 未提供）。
   别去装假的 lsb_release 糊弄它，直接绕过整个脚本。
   ⚠️ 判断是**短路求值**：`[ "$VER" \< "22.04" ]` 先判，空 VER 就已经为真。
   工具的处理：遇到 `Exec=` 是 `*launch.sh|*start.sh|*run.sh|*.sh` 时，在同目录里
   找与目录同名（`/opt/mailmaster` → `mailmaster`）或与 desktop 同名的可执行文件
   当替身。人工排查时同理 —— **别 exec 那个 sh**。

2. **Debian 专属运行库缺失**（`ldd | grep "not found"` 定位）
   - `libnss_wrapper.so`：**Arch 全仓库（含 archlinuxcn）都没有**，`pacman -F`
     查不到，只能从 Debian 取；
   - `libsasl2.so.2`：Arch 的 `libsasl` 只给 `.so` 和 `.so.3`。
     可以软链（`ln -s /usr/lib/libsasl2.so.3 <compat>/libsasl2.so.2`，ABI 2↔3 兼容），
     但**从 Debian 取 `libsasl2-2` 更干净** —— 工具走的就是这条。
   - 库统一放 `~/.local/lib/debcompat/`，启动器里 `LD_LIBRARY_PATH` 指过去。

   **怎么从 Debian 取库（这套查询方法很通用，值得记住）**：
   ```bash
   # ① soname → Debian 二进制包名：查 Contents 索引
   #    结果在页面唯一那张 <table> 里，形如 <a href="/trixie/libnss-wrapper">…
   #    ⚠️ 直接 GET 这个 URL 会跳转，用 curl -L；Python urllib 拿到的可能是
   #       language 选择页，解析不出结果 —— 用 curl。
   curl -fsSL 'https://packages.debian.org/search?searchon=contents&keywords=libnss_wrapper.so&mode=exactfilename&suite=stable&arch=amd64'
   # ② 包名 → .deb 直链：查 download 页，抓任一镜像的 pool/… 相对路径
   curl -fsSL 'https://packages.debian.org/trixie/amd64/libnss-wrapper/download'
   # ③ 统一拼官方 CDN（别用「去掉 http://host/ 前缀」的写法 —— 镜像 URL 是
   #    http://host/debian/pool/… ，去掉 host 还剩 debian/，再拼就重复了）
   #    → https://deb.debian.org/debian/pool/main/n/nss-wrapper/libnss-wrapper_1.1.16-1_amd64.deb
   ```
   `archive.ubuntu.com` 的 `pool/universe/libn/…` 路径 **404，别走**；
   `deb.debian.org/debian/pool/main/<源码包名>/` 才对，注意 pool 用**源码包名**
   （`libnss-wrapper` 的源码包是 `nss-wrapper`），所以不要手工拼路径，按 ① ② 查。

3. **自带 Qt5 的 GLX 集成在新版 Mesa 上段错误**
   现象：无任何日志直接 SIGSEGV；`coredumpctl info` 堆栈是关键证据：
   ```
   #0 0x0 n/a
   #1 XML_ParseBuffer (libexpat.so.1)
   #2-9 libGLX_mesa.so.0
   #10 QXcbGlxWindow::createVisual (libqxcb-glx-integration.so)
   #11 QXcbWindow::create (libQt5XcbQpa.so.5)
   ```
   解法（二选一，实测结论）：
   - **`QT_XCB_GL_INTEGRATION=none`** ✅ 禁用 GLX 集成，走光栅化渲染，正常启动
   - `LIBGL_ALWAYS_SOFTWARE=1` ❌ 仍然 SIGSEGV（只是换了个崩溃点）

**应用专属修复写在 `.env`，不要写进启动器**（工具重新生成启动器时会覆盖）：

```bash
# ~/.config/debinstall/<app>.env
export QT_XCB_GL_INTEGRATION=none   # 规避 Qt5 GLX 在 Mesa 上的空指针崩溃
export QT_QPA_PLATFORM=xcb          # 自带 Qt 只有 xcb 插件，避免探测 wayland 失败
```

**入口一定要放用户级**：`~/.local/share/applications/<app>.desktop` 优先级高于
`/usr/share/applications/`，`Exec=` 指向启动器。这样**不碰 root 文件**，
卸载/升级 `.deb` 时也不被覆盖。工具生成的用户级 desktop 带
`X-DebInstall-Wrapper=1` 标记，用来区分「自己的入口」和「用户的定制」。

**验证要点**：`pgrep -c -x <binary>` 应有 5-8 个进程；`coredumpctl list --since`
比对启动前后有无新 SIGSEGV 记录（比看日志可靠，崩溃时日志常常是空的）；
日志里的 `Channel error ... code 5`、`Get file data fail: /mkt/...` 是无害噪音。

### 这次在工具里修掉的四个坑（都已加进回归检查 11 节）

1. **缺失库只报告不处理**。原来只打印「装之前应补上」，然后照样装，装完启动不了。
   现在自动从 Debian 补库 + 生成兼容启动器。`analyze` 输出也会说明会怎么补。
2. **桌面快捷方式被静默覆盖**。原 `make_desktop_shortcut` 无条件 `cp -f`，
   用户改过的 `Exec`（比如指向自己写的兼容启动器）重装一次就退回坏状态。
   现在：内容相同则跳过，不同则先备份成 `.desktop.bak-<时间戳>`。
3. **遮蔽冲突提示方向单一**。原提示无脑建议 `mv ~/.local/...{,.bak}`，
   但当用户级那份是**修好的**、系统级那份是坏的时候，照做等于自毁。
   现在按 `Exec` 可执行性分四种情况给建议，且认得自家的 wrapper 标记。
4. **目录权限 775 照搬**。`.deb` 里目录常是 `drwxrwxr-x`，照搬会导致 pacman 对
   已存在的 `/opt`、`/usr/share` 报「目录权限不一致」，且包新建的 `/opt/<app>`
   组内可写（组里有人就能替换应用二进制）。现在打包前 `find <root> -type d
   -exec chmod go-w {} +`，只动目录不动文件；`DEBINSTALL_KEEP_DIR_PERM=1` 可关。

## 完善 desktop 文件

deb 自带的 `Categories` 经常是 `Utility;`（归错菜单）。改成合适的：

```ini
[Desktop Entry]
Name=AppName
Name[zh_CN]=中文名
GenericName=Music Player
GenericName[zh_CN]=音乐播放器
Comment[zh_CN]=中文说明
Exec="/opt/AppDir/binary" %U
Terminal=false
Type=Application
Icon=appname
StartupWMClass=<Electron的WM_CLASS>
StartupNotify=true
MimeType=x-scheme-handler/<scheme>;
Categories=AudioVideo;Player;Audio;
```

改完校验：`desktop-file-validate /usr/share/applications/xxx.desktop`

## 验证清单

```bash
export WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/run/user/1000 DISPLAY=:0

# 1. 依赖完整性（最要紧，缺库直接起不来）
ldd "/opt/<AppDir>/<binary>" | grep "not found" || echo "✓ 依赖齐全"

# 2. 真正启动（必须去掉污染变量）
setsid env -u ELECTRON_RUN_AS_NODE "/opt/<AppDir>/<binary>" >/tmp/run.log 2>&1 </dev/null &
sleep 12
pgrep -x <binary> | wc -l              # Electron 正常有 5-8 个子进程
cat /tmp/run.log                       # 找 "DOM Ready" / "Page Loaded" 等成功标志

# 3. 截图确认窗口（grim 不可用，用 spectacle）
spectacle -b -n -o /tmp/shot.png
```

**成功的日志长这样**（electron-builder 打包的应用）：
```
Checking for beta autoupdate feature for deb/rpm distributions
Found package-type: deb
API服务器已启动
DOM Ready
Page Loaded Successfully
```

无害的常见警告，不用管：
- `Gtk-Message: Failed to load module "appmenu-gtk-module"`
- `xdg-settings: invalid application name`

## 固化 .deb 双击打开的默认程序

`deb-install.desktop` 里声明了 `MimeType=application/vnd.debian.binary-package`，
但**光有声明不够** —— 本机的 `org.kde.ark.desktop`（压缩包管理器）也认这个类型，
不显式指定默认，双击可能被 Ark 抢走。要主动固化：

```bash
xdg-mime default deb-install.desktop application/vnd.debian.binary-package
```

配置会写到 `~/.config/mimeapps.list` 的 `[Default Applications]` 段：

```ini
application/vnd.debian.binary-package=deb-install.desktop
```

验证（这一步不能省，光看 query 结果不够）：

```bash
xdg-mime query default application/vnd.debian.binary-package   # → deb-install.desktop
setsid xdg-open /path/to/x.deb &                               # 应弹出安装器窗口
pgrep -af deb-install-ui                                       # 确认进程真的起来了
```

两个收纳细节：

- `~/.local/share/applications/mimeapps.list` 是**老位置**，现已被 `~/.config/mimeapps.list`
  取代。如果那里残留一个空文件，容易让人误以为关联没生效 —— 直接删掉。
- `Categories=` 里**主类别只能有一个**（`System;Settings;` 会触发「可能重复出现」提示）。
  用 `Settings;PackageManager;`：前者是唯一主类别，后者是子类别。
  改完用 `desktop-file-validate <file>` 应无任何输出。
- `xdg-mime` 在 KDE 下会打印 `qtpaths: 未找到命令` —— 那只是它探测 Qt 环境失败，
  **不影响配置写入**，别被这行吓到。

## 打包分发（要给别的机器用时）

本机成品在 `~/deb-tools/packaging/`，跑 `./build.sh` 会从 `~/.local/bin`
同步最新代码、落版本号、打成 `dist/debinstall-<ver>.tar.gz`。
安装脚本支持 `PREFIX=`（默认 `~/.local`），装完写
`$PREFIX/share/debinstall/manifest.txt` 记账，卸载脚本照着清单删。

### 坑 1：安装时的 `sed` 替换会把「校验行」一起干掉

为了让装到 `/opt` 这种非标准位置也能跑，主程序里留了个占位符
`@PREFIX_BIN@`，安装时 `sed` 换成真实路径。**但 `sed` 是全局替换**，
如果代码里还有一处 `if "@PREFIX_BIN@" in cand: continue` 用来跳过
「占位符还没被替换」的候选，那行**也会被换成真实路径** ——
于是装好之后这个判断反而把自己的正确路径给跳过了。

现象很隐蔽：本机因为 `~/.local/bin` 里恰好也有一份，走 PATH 兜底还能用，
换到干净机器就找不到主程序。

```python
# 错：校验用的字面量会被一起替换
if "@PREFIX_BIN@" in cand: continue

# 对：标记拼开写，sed 匹配不到这一行，但运行时值相同
_PH = "@PREFIX_" + "BIN@"
...
if _PH in cand: continue
```

验证要**两个状态都测**：源码树里跑（应跳过占位符候选）、
模拟 `sed` 替换后跑（应命中）。测试时把 `PATH` 清空，
逼它必须靠替换后的绝对路径，否则会被 PATH 兜底掩盖。

### 坑 2：卸载脚本必须由清单驱动，不能「顺手清理」

第一版卸载脚本会无条件删技能文档、无条件清 `.deb` 关联。
结果：用 `--no-skill` 装到 `/tmp/xxx` 的测试实例一卸载，
把**另一个安装位置**（真实 `~/.local`）的技能文档和 `.deb` 关联一起干掉了。
卸载一个 `/tmp` 测试目录却动了系统状态，属于典型的越权。

两条规矩：

```bash
# 1. 技能文档这类「共享资源」：只有清单里记着才删
SKILL_INSTALLED=0
for f in "${FILES[@]}"; do
    if [ "$f" = "$SKILL_DIR/SKILL.md" ]; then SKILL_INSTALLED=1; fi
done

# 2. 只在自己处于 XDG 搜索路径里时，才有资格改默认程序
#    装到 /tmp 或 /opt 的实例，xdg-mime 指向的根本不是它
_app_dir_is_authoritative() {
    local dir="$PREFIX/share/applications" d
    [ "$dir" = "${XDG_DATA_HOME:-$HOME/.local/share}/applications" ] && return 0
    for d in ${XDG_DATA_DIRS:-/usr/local/share:/usr/share}; do
        [ "$dir" = "$d/applications" ] && return 0
    done
    return 1
}
```

**测卸载一定要隔离 `HOME`**，否则测一次毁一次真实环境：

```bash
rm -rf /tmp/dt-h && mkdir -p /tmp/dt-h
HOME=/tmp/dt-h PREFIX=/tmp/dt-p ./install.sh --no-mime --no-skill
HOME=/tmp/dt-h PREFIX=/tmp/dt-p /tmp/dt-p/share/debinstall/uninstall.sh
```

顺带两条：

- GUI 脚本的检测**不能用 PATH 里的 `python3`** —— 本机 PATH 前面是
  WorkBuddy 托管的 python，没有 `gi`，会把「图形界面可用」误判成不可用。
  要按脚本 shebang 里的解释器检测（`head -1 <file> | sed 's|^#!||'`），
  本机即 `/usr/bin/python3`。
- GUI 脚本的 shebang 保持 `#!/usr/bin/python3` 不要改成 `env python3`：
  `gi` 是 pacman 装在系统 python 下的，走 `env` 可能命中没装 `gi` 的 python。

### 开发资料包（交给其他 AI 继续开发时）

完整逻辑说明、源码快照与回归检查在 `~/deb-tools/devkit/`，
打成 `~/deb-tools/devkit-2.0.1.tar.gz`（附 `.sha256`）。内容：

| 文件 | 用途 |
|---|---|
| `README.md` | 入口索引 |
| `AI-PROMPT.md` | **可直接粘贴给其他 AI 的引导语**（短版/长版/任务片段） |
| `DESIGN.md` | 10 章逻辑说明书（算法权威描述） |
| `REFERENCE.md` | 速查表（选项/函数/格式/正则/环境变量） |
| `HANDOFF.md` | 接手手册（环境/测试/改动配方/禁忌） |
| `src/` | 源码快照（与 `~/.local/bin` 逐字节一致） |
| `test/` | 造测试包 + 110 项回归检查 |

回归检查 `devkit/test/run-checks.sh` 基线 110/110 全过，且**绝不真装东西**
（门禁测试用「危险命令只在注释里」的探针包，并断言 pacman.log 未变）。
⚠️ `/tmp/debtest/evil_*.deb` 是**真恶意样例**，仅供人工查看，绝不要 `--install`。

**改完代码后必须同步这三处，否则打出来的包自带落后代码**（踩过）：
`devkit/src/` ← 从 `~/.local/bin/` 拷；`devkit/src/run-checks.sh` 与
`devkit/test/run-checks.sh` 是两份独立副本，必须保持一致；
本 SKILL.md 也要拷一份到 `devkit/src/SKILL.md`。

## 收尾

如果替换掉了玲珑版，**新旧并存会浪费空间且入口混乱**，卸载旧的：

```bash
ll-cli uninstall <旧id>          # 用户数据在 ~/.config/<app>，不受影响，可随时重装回退
ll-cli list | grep -i <关键词>   # 确认为空
```

清理临时文件：`rm -rf /tmp/work /tmp/<app>-*.log /tmp/<app>-*.png`
