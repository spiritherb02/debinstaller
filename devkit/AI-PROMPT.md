# AI-PROMPT.md —— 给其他 AI 的引导语

本文件是**一段可以直接粘贴给另一个 AI（或另一个会话）的提示词**，
用来让它在这套 `debinstall` 代码上继续开发。下面「短版」日常够用；
换新模型、或它老是跑偏时用「长版」。

---

## 短版（直接复制这一段）

```
我在 Arch Linux 上有一套自研工具 debinstall，作用是把外来 .deb 包
转换成真正的 pacman 包再安装（因为 Arch 上跑不了 dpkg/alien）。

工程资料在这个目录：~/deb-tools/devkit/
  - DESIGN.md    逻辑说明书（10 章，算法的权威描述）
  - REFERENCE.md 速查表（命令行选项、函数、文件格式、环境变量）
  - HANDOFF.md   接手手册（环境、测试、改动配方、待办、禁忌）
  - AI-PROMPT.md 本文件
  - src/         源码快照（版本 2.0.1）
  - test/        测试包生成器 + 回归检查脚本

运行时真正生效的代码在 ~/.local/bin/（debinstall 是引擎）。
改代码要改那里；src/ 只是快照，packaging/ 是打包中转。

请先按这个顺序读：DESIGN.md 第 2 章 → 第 4 章 → 第 7 章 → 第 9 章，
再读 HANDOFF.md 的「不要做的事」。

三条不可破坏的约束：
1. 默认只读：不带 --install / -l 绝不写系统。
2. GUI 靠匹配引擎 stdout 的中文字面串工作，改输出文案会静默弄坏 GUI；
   动手前先看 DESIGN.md 第 7 章。
3. 这是以 root 运行、处理不可信输入的代码，改动取向要更保守，不是更方便。

我要你做的事：<在这里写你的需求>

改完请跑：~/deb-tools/devkit/test/run-checks.sh（当前基线 110/110 全过）。
若改了 DANGER_RE 或打包逻辑，另见 HANDOFF.md §4.4 / §5.5。
```

---

## 长版（换模型 / 需要更强约束时用）

```
# 背景

Arch Linux 与 Debian 的包管理互不兼容。大量软件只发 .deb（Chrome、Edge、
VS Code、JetBrains、国产软件……）。本机有一套自研工具 debinstall，核心做法是：
把 .deb 转换成真正的 Arch 包（生成 .PKGINFO/.MTREE/.INSTALL）再交给 pacman -U，
这样装出来的东西被 pacman 完整跟踪，-Q/-Ql/-Qo/-R 都正常，不产生野文件。

它有三条安装路线（DESIGN.md 第 2 章）：
  A 转换 + pacman（系统级，推荐）
  B ~/.local 本地安装（不需要 root，隔离）
  C 直接 tar -xf 到 /（deb-install-raw，最后手段）
另有 ELF→pacman 的 soname 反查、update-alternatives 内嵌 shim、
危险维护脚本门禁等机制。

# 资料在哪

所有文档在 ~/deb-tools/devkit/：
  DESIGN.md      逻辑说明书，10 章；算法的权威描述，全部对着源码核对过（2.0.1 新增第 5.8 节）
  REFERENCE.md   速查表：命令行选项、内部函数签名、文件格式、DANGER_RE、
                 BUILTIN_MAP、GUI 正则、环境变量、外部命令依赖
  HANDOFF.md     接手手册：环境搭建、测试、常见改动配方、待办、禁忌清单
  src/           源码快照（2.0.1），只读参考
  test/          make-test-debs.sh（造 7 个测试包，含恶意样例）
                 run-checks.sh（110 项回归检查）

运行时生效的代码：~/.local/bin/debinstall（引擎，事实来源）
                  ~/.local/bin/deb-install-ui（GTK 图形界面）
                  ~/.local/bin/deb-install-askpass（无 tty 时的图形密码框）
                  ~/.local/bin/deb-install-raw（路线 C）
                  ~/.local/bin/deb-install-open（孤儿脚本，无人调用）
                  ~/.local/share/applications/deb-install.desktop
改代码改 ~/.local/bin/ 下那几个；src/ 和 packaging/bin/ 都不是事实来源。

# 阅读顺序（务必）

1. DESIGN.md 第 2 章  三条路线及取舍
2. DESIGN.md 第 4 章  一次完整调用的数据流
3. DESIGN.md 第 7 章  GUI↔引擎的文本契约（★ 改输出前必读）
4. DESIGN.md 第 9 章  9 个已知缺陷
5. HANDOFF.md 第 7 章 「不要做的事」（10 条禁忌，每条都踩过坑）
6. HANDOFF.md 第 5 章 常见改动配方（加依赖映射 / 加危险模式 / 加命令行模式）

# 不可破坏的约束（不变量，DESIGN.md 第 8 章有完整列表）

1. 默认只读。不带 --install / -l 就绝不写系统。分析逻辑只有一份，
   --install 内部先复用完整只读分析再问确认。
2. GUI 靠 8 个中文字面串匹配引擎 stdout。改文案前先查 DESIGN.md §7.3。
   正解是先做 --json（HANDOFF.md §6 第 1 优先），再动文案。
3. 非交互（管道 / GUI / CI）下遇到高危包必须拒绝（die），
   除非显式 --allow-dangerous。绝不能把 [ -t 0 ] 为假当成"用户同意"。
4. 移除期钩子（prerm/postrm）默认不执行，这是刻意的保守取舍。
5. 打包命令里绝不能出现 bsdtar -n（它是 --no-recursion，会打出空包且不报错）。
6. GUI 的 shebang 必须是 /usr/bin/python3（gi 装在系统 python 下）。
7. deb-install-ui 里的 "@PREFIX_BIN@" 标记必须拼开写（"@PREFIX_" + "BIN@"），
   否则安装时的 sed 会把校验行也替换掉，反而跳过正确路径。

# 环境与测试

依赖：sudo pacman -S dpkg libarchive fakeroot zstd binutils
GUI ：sudo pacman -S python-gobject gtk3
前置：确保 /var/lib/pacman/sync/*.files 存在（否则 pacman -F 失效，
      依赖解析会静默产出空结果）—— 没有就跑 sudo pacman -Fy

造测试包：~/deb-tools/devkit/test/make-test-debs.sh   （输出到 /tmp/debtest/）
回归检查：~/deb-tools/devkit/test/run-checks.sh        （基线 110/110 全过）
    run-checks.sh 是安全的：绝不真的装东西；门禁测试用 evilprobe
    （危险命令只在注释里），并断言 pacman.log 行数不变。
    注意 /tmp/debtest/evil_*.deb 是【真恶意样例】，仅供人工查看，绝不要 --install。

# 我要你做的事

<在这里写你的需求>

# 交付要求

- 只改 ~/.local/bin/ 下的运行时代码；不要改 src/（那是快照）。
- 改动后跑 run-checks.sh，要 110/110；涉及 GUI 文案则确认 8 个字面串仍在。
- 涉及危险正则的改动，跑 HANDOFF.md §4.4 的正/反样例两边。
- 报告：说明改了哪几个文件、为什么、如何验证、是否影响不变量。
```

---

## 附：几种常见需求的「任务」段落替换示例

把上面 `<在这里写你的需求>` 换成下面任一段即可。

**加 --json 输出**（最高优先级，见 HANDOFF.md §6）
```
给 debinstall 加一个 --json 选项，每行输出一个 JSON 对象（流式），
覆盖 pkg / script / deps / conflict / result 五类。schema 见 HANDOFF.md §6。
GUI 侧改成优先读 JSON、解析失败回退现有文本匹配，保证两者可独立演进。
改动后 run-checks.sh 必须仍全过，并补测 JSON 分支。
```

**修依赖解析静默失败**（DESIGN.md §9.3，风险最高）
```
修依赖解析的静默失败：build_arch_pkg 开头检查 /var/lib/pacman/sync/*.files
是否存在；若存在 soname 但零映射，明确告警而不是默默产出空依赖表。
```

**加一条依赖映射**
```
往 BUILTIN_MAP 加映射：<Debian名> → <Arch名>。
用 printfake_1.0.0_amd64.deb 验证 debinstall 输出里出现新映射。
```

**加一个危险模式**
```
给 DANGER_RE 增加分支：<描述要拦的命令>。
约束：POSIX ERE，用 [[:space:]] 不用 \s，尾部锚定 (\s|$)，
跨管道用 [^|]* 限制。改完把 HANDOFF.md §4.4 的正/反样例都跑一遍。
```

**收尾两个孤儿脚本**
```
处理 deb-install-open 与 deb-install-raw（无人调用，DESIGN.md §9.5）：
给 debinstall 加 --raw 转发；deb-install-open 要么删，要么做成
终端模式的 desktop 变体。给出你的取舍建议再改。
```

---

## 附：给 AI 的收尾提醒（可一并粘贴）

```
最后请自查（对应 HANDOFF.md 第 7 章）：
- 有没有往 stderr 写正常信息？（GUI 合并 stderr→stdout，块缓冲会乱序）
- 有没有让 analyze_deb 直接 die？（它应只报告不阻断，除非加 --strict）
- 有没有动 _db_run 里的 >/dev/null 2>&1 或 || true？
- 有没有把 [ -t 0 ] 当成"有人看着"？
- usage() 的行号提取（sed -n '3,13p'）有没有因为改头部注释而错位？
```
