# debinstaller

在 **Arch Linux** 上安装 Debian `.deb` 包的小工具。

`dpkg`/`apt` 在 Arch 上不存在，直接解包又会绕过包管理器。debinstaller 的
做法是：**把 .deb 转换成原生 pacman 包，再交给 `pacman -U` 安装**，这样
文件冲突检查、升级、卸载、`pacman -Qo`/`-Ql` 查询全部正常工作。

```
.deb ──► 解包 data.tar ──► 生成 .PKGINFO ──► tar + zstd ──► pacman -U
         解析 control      依赖映射/backup
```

## 功能

- 解析 `.deb`（ar + control.tar/data.tar，支持 gz/xz/bz2/zst）
- 自动把 Debian 依赖映射为 Arch 包名（内置 300+ 条映射表 + 启发式规则）
- 用 `pacman -T` / `pacman -Si` 判断依赖是已满足、可安装还是未知
- 生成标准 pacman 包，`/etc` 下的文件自动写成 `backup` 条目
- 用 JSON 记录安装历史（`/var/lib/debinstaller/state.json`），支持 `list` / `remove`
- 可选执行 Debian 维护者脚本（`--run-scripts`，默认不执行）
- 没有 pacman 时退化为直接拷贝文件安装

## 安装

```bash
sudo ./install.sh            # 安装到 /usr/local
sudo PREFIX=/usr ./install.sh
sudo ./install.sh --uninstall
```

也可以不安装，直接用 `./bin/debinstall` 运行。

依赖：Python 3.8+、`zstd`（缺失时自动改用 xz）、根权限（安装/卸载时）。

## 用法

```bash
debinstall info  package.deb          # 查看元数据
debinstall deps  package.deb          # 依赖映射报告（--json 可机读）
debinstall convert package.deb        # 只转换成 pacman 包，不安装
debinstall install package.deb        # 转换并安装
debinstall install --install-deps -y package.deb
debinstall list                       # 列出由本工具安装的包
debinstall remove <name>              # 卸载（--run-scripts 可跑 prerm/postrm）
debinstall extract package.deb [dest] # 仅解包查看
```

常用选项：

| 选项 | 说明 |
| --- | --- |
| `-n, --name NAME` | 覆盖 pacman 包名 |
| `--install-deps` | 用 pacman 自动安装缺失的映射依赖 |
| `--strict-deps` | 有未解析依赖时直接失败 |
| `--all-deps`（convert） | 无论本机是否安装，全部写入包元数据 |
| `--no-deps` | 跳过依赖分析 |
| `--run-scripts` | 以 root 执行 preinst/postinst/prerm/postrm |
| `--dry-run` | 只构建不安装 |
| `--keep-package` | 保留生成的 pacman 包 |
| `--ignore-arch` | 忽略架构不匹配 |
| `-o, --output DIR` | 转换后包的输出目录 |

示例：

```console
$ debinstall install ~/Downloads/linglong-store_3.5.0_amd64.deb
==> linglong-store 3.5.0 [amd64]
==> dependencies: 5 groups — 5 satisfied, 0 missing, 0 unknown, 0 debian-only
 --> converted to pacman package: /var/cache/debinstaller/linglong-store-3.5.0-1-x86_64.pkg.tar.zst
==> running: pacman -U --noconfirm /var/cache/debinstaller/linglong-store-3.5.0-1-x86_64.pkg.tar.zst
==> installed linglong-store 3.5.0-1
 --> remove with: debinstall remove linglong-store
```

## 依赖映射

映射逻辑在 `debinstaller/depmap.py`：

- `MAP`：Debian 包名 → Arch 包名，例如 `libc6 → glibc`、`libgtk-3-0 → gtk3`
- `SKIP`：Arch 上无意义的 Debian 运行时依赖（`debconf`、`dpkg` 等）
- 启发式：`python3-foo → python-foo`、`libfoo-dev → foo`
- 其余同名软件按原名处理，并用 pacman 数据库核实

发现映射缺失时，直接往 `MAP` 里加一行即可，欢迎提 PR。

## 包名冲突策略

| 情况 | 行为 |
| --- | --- |
| 仓库里已有同名包 | 自动改名为 `deb-<name>`，避免遮蔽官方包 |
| 本机已安装同名包 | 沿用原名（`pacman -U` 视为升级/替换）并给出警告 |
| 本工具装过同名包 | 沿用原名，直接升级 |

## 已知限制

- **维护者脚本默认不执行。** Debian 脚本假设 dpkg 环境，在 Arch 上
  可能出错；需要时用 `--run-scripts` 显式启用（风险自负）。
- 不处理 `triggers`、`Pre-Depends`、debconf 配置。
- 依赖映射是尽力而为：`unknown` 的依赖只会警告，不会阻断安装。
- `conffiles` 只映射为 pacman 的 `backup`，不实现 dpkg 的三方合并语义。
- `.deb` 的 `data.tar` 会完整读入内存后再解包，超大包慎用。

## 测试

```bash
python3 tests/run_tests.py
```

测试会现场构造一个合成 `.deb`，覆盖解析、安全解包（拒绝 `../` 路径）、
版本转换、依赖映射、pacman 包生成和 CLI 转换流程。

## 目录结构

```
bin/debinstall              # 开发入口
debinstaller/
  arfile.py                 # ar 归档读写
  archive.py                # tar/zstd 辅助
  debfile.py                # .deb 解析与安全解包
  depmap.py                 # Debian → Arch 依赖映射
  pacmanpkg.py              # .PKGINFO 与 pacman 包生成
  store.py                  # 安装状态数据库
  cli.py                    # 命令行界面
tests/run_tests.py          # 自包含测试
install.sh                  # 安装脚本
```

## License

MIT
