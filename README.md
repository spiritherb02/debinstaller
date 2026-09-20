# 软件包安装程序（debinstall）

在 **Arch Linux** 上安装 Debian/Ubuntu 的 `.deb` 包，顺带把 `.AppImage` 收进应用菜单。

Arch 和 Debian 的包管理是两套东西，官方没有交叉安装的途径。这个工具的做法是：
把 `.deb` **转换成一个真正的 Arch 包**（生成 `.PKGINFO`、`.MTREE`、`.INSTALL`），
再用 `pacman -U` 装进去 —— 所以装完之后 **pacman 认识它**，`pacman -Q` 查得到、
`pacman -R` 卸得掉，不会在系统里留下"野文件"。

同时它也保留了另一种更"粗"的模式：直接解包铺到 `/`（不走 pacman）。
两种模式各有取舍，见下文。

---

## 为什么需要它

很多软件只发 `.deb`：Google Chrome、VS Code、Edge、JetBrains 系列、
以及大量国产软件。Arch 用户常见的做法有三种，都不太理想：

| 做法 | 问题 |
|------|------|
| `bsdtar -xf xxx.deb -C /` 直接铺 | 系统不认识它；卸载靠手动删文件；依赖全靠自己碰运气 |
| 找 AUR 里有没有对应包 | 不一定有；有的话也不一定同步 |
| 手动 `--force` 装 Debian 包 | 会污染 pacman 数据库 |

debinstall 想解决的就是这个：**先看清楚这个包要干什么，再决定装不装、怎么装。**

---

## 安装

### 发布包（推荐）

从 [Releases](../../releases) 下载 `debinstall-<版本>.tar.gz`：

```bash
tar -xzf debinstall-2.1.0.tar.gz
cd debinstall-2.1.0
./install.sh
```

### Git 仓库

仓库根目录就是发布包的结构，克隆下来直接装：

```bash
git clone https://github.com/spiritherb02/debinstaller.git
cd debinstaller
./install.sh
```

默认装到 `~/.local`，不需要 root。装到系统目录：

```bash
sudo PREFIX=/usr/local ./install.sh
```

选项：

| 选项 | 作用 |
|------|------|
| `--no-mime` | 不把 `.deb` / `.AppImage` 的双击打开方式改成它 |
| `--no-skill` | 不安装 WorkBuddy 技能文档 |
| `--dry-run` | 只打印会做什么，不实际改动 |
| `--prefix <路径>` | 等价于 `PREFIX=<路径>` |

装完会用 `~/.local/share/debinstall/manifest.txt` 记账，方便卸载。

### 依赖

安装脚本会自己检查，缺哪个会告诉你。手动核对的话：

```bash
sudo pacman -S dpkg libarchive fakeroot zstd binutils   # 必需
sudo pacman -S desktop-file-utils gtk-update-icon-cache xdg-user-dirs polkit  # 可选
sudo pacman -S python-gobject gtk3                       # 图形界面才需要
sudo pacman -S p7zip                                     # 只看 .AppImage 才需要
```

没有图形依赖时，命令行部分照常工作，只是双击 `.deb` 没反应。

---

## 用法

### 命令行

```bash
deb-install 某个包.deb              # 只读体检：看依赖、看安装脚本、看会往哪写文件
deb-install --install 某个包.deb    # 确认后真的装（需要 root）
deb-install -l 某个包.deb           # 装到 ~/.local，完全不需要 root
deb-install -c 某个包.deb           # 只转换，生成 Arch 包但不安装
deb-install -R 包名                 # 卸载（pacman 记账的用这个）
deb-install --raw 某个包.deb        # 不走 pacman，直接解包铺到 /
```

**默认什么都不装。** 不带参数跑一遍就是一份"体检报告"，看完再决定。

### 图形界面（软件包安装程序）

双击 `.deb` 或 `.AppImage` 文件（`--no-mime` 之外的情况下会自动关联），
或者手动启动 `deb-install-ui`。

`.deb` 走引擎：列出包信息、依赖能不能满足、安装脚本里有没有危险动作、
会往系统哪些地方写文件。确认之后才动手。

`.AppImage` 走 GUI 自己的分支，不碰引擎也不需要 root：只用 `file`/`7z`
**只读**看一眼（绝不执行不可信二进制），然后把文件移进 `~/Applications`、
补上可执行位、抽出图标并注册进应用菜单，同时写一份卸载清单到
`~/.local/debinstall/appimages/`。AppImage 是不透明的单一二进制，
没有安装脚本可审，所以确认框里会明确告诉你"这条路径查不了依赖"。

---

## 两种安装模式

| | `--install`（转包 + pacman） | `--raw`（直接铺开） |
|---|---|---|
| pacman 记账 | ✅ 能查能卸 | ❌ 不管 |
| 依赖解析 | ✅ 自动查 soname → pacman | ❌ 自己碰运气 |
| 卸载 | `pacman -R` 干净 | 手动删文件 |
| 兼容性 | 偶尔有文件冲突 | 基本都能装上 |
| 适用 | 首选 | 转包失败时的兜底 |

`--raw` 存在的意义是：有些 `.deb` 转成 Arch 包之后会因为文件冲突装不上，
这时候铺开式反而能过。但代价是系统不认识它。

`-l` 本地模式是第三种，装到 `~/.local` 下，不需要 root，
适合试用或者没有 sudo 的场景。

---

## 安全性

`.deb` 的安装脚本（`preinst` / `postinst` / `prerm` / `postrm`）是以
**root 身份执行**的任意 shell。也就是说，一个恶意 `.deb` 里的
`postinst` 写一句 `rm -rf /` 就能真的执行。这是 Debian 包格式本身的性质，
不是哪个工具能绕过的。debinstall 做了这么几件事：

1. **默认只读。** 不加 `--install` / `--raw` 就绝不写系统。
2. **危险动作扫描。** 安装脚本里出现 `rm -rf /`、`dd of=/dev/sd*`、
   `mkfs.`、`curl … | sh`、`chown -R … /` 这类模式会标红警告。
   高风险包在非交互场景下（管道、图形界面、脚本调用）**直接拒绝安装**，
   必须显式加 `--allow-dangerous` 才继续。
3. **卸载钩子默认不执行。** `prerm` / `postrm` 是卸载时才跑的、
   同样以 root 执行。默认不把它们写进 Arch 包，避免"装的时候没事、
   卸的时候中招"。要的话加 `--run-remove-hooks`。
4. **装之前列出会动哪些路径。** 让你看清它要往 `/etc`、`/usr` 里塞什么。

**但请记住：这些只是降低风险，不是沙箱。** 装来源不明的 `.deb` 之前，
至少要跑一遍只读体检，看不懂安装脚本就别装。

---

## 已知限制

- **只在 Arch 系（pacman）上能用。** 其他发行版没意义。
- **依赖不一定都能满足。** Debian 的包名和 Arch 不一样，工具靠
  `pacman -F` 反查 ELF 需要的 `lib*.so` 来找对应包，
  找不到的会在报告里列出来，需要你自己判断替代品。
- **`update-alternatives` 是模拟的。** Arch 没有这个机制。
  工具内置了一个 shim，让靠它建立通用命令名（比如 `figlet`）的包能正常工作。
  本地模式（`-l`）下，绝对路径引用的替代项可能失效，报告里会提示。
- **转包不是万能的。** 某些包的安装脚本做了深度的系统集成，
  转成 Arch 包后行为可能和 Debian 上不完全一样。
- **AppImage 分支只看元数据。** 不检查依赖、不审安装脚本（AppImage 里
  也没有），并且目前没有图形化的卸载入口 —— 手动删 `~/Applications` 里
  那个文件和 `~/.local/share/applications/<名字>.desktop` 即可。

---

## 卸载

```bash
~/.local/share/debinstall/uninstall.sh
```

会按安装时记的清单逐个删掉，并解除 `.deb` / `.AppImage` 关联。
**不会**动你用 debinstall 装过的那些软件包 —— 那些是 pacman 管的，
自己用 `pacman -R <包名>` 卸。

选项：`--keep-skill`（保留技能文档）、`--dry-run`（只看不删）。

---

## 关于 WorkBuddy 技能文档

`share/doc/SKILL.md` 是这个工具开发过程中积累的经验笔记，
安装时会放到 `~/.workbuddy/skills/arch-install-deb/`。
作用是在用 AI 助手处理 `.deb` 安装时，让它自动套用这些结论
（比如"`pacman -F` 要批量调用否则极慢"、"`[ -t 0 ]` 在管道下会静默失效"）。
不用 WorkBuddy 的话加 `--no-skill` 跳过，或者直接删掉那个目录。

---

## 仓库结构

```
.
├── install.sh                      # 安装脚本
├── uninstall.sh                    # 卸载脚本
├── build.sh                        # 从 bin/ 打发布 tar.gz（+ sha256）
├── README.md
├── PKGBUILD                        # Arch 打包（用发布 tar.gz 作 source）
├── bin/
│   ├── debinstall                  # 主程序（分析 / 转换 / 安装 / 卸载）
│   ├── deb-install-ui              # GTK3 图形界面
│   ├── deb-install-open            # 打开 .deb 的入口（给 xdg 用）
│   ├── deb-install-askpass         # 图形界面里要 sudo 密码时的对话框
│   └── deb-install-raw             # 铺开式安装的独立实现
├── share/
│   ├── applications/deb-install.desktop
│   └── doc/SKILL.md
└── devkit/
    ├── DESIGN.md                   # 设计文档；★ 第 7 章是引擎↔GUI 的输出契约
    ├── HANDOFF.md                  # 接手笔记：改动配方、禁区、自检
    ├── REFERENCE.md                # 细节参考
    ├── AI-PROMPT.md                # 喂给 AI 助手的项目上下文
    └── test/
        ├── run-checks.sh           # 回归自检（改代码后必须跑）
        ├── make-test-debs.sh       # 生成测试用 .deb
        └── probe-appimage.py       # 不弹窗口地跑 AppImage 只读扫描
```

装完之后 `deb-install` 是 `debinstall` 的软链接。

> `bin/` 里的文件由 `build.sh` 从开发机的 `~/.local/bin` 同步而来。
> 直接改 `bin/` 也能用，但记得同步回你的运行目录，否则下次打包会覆盖。
