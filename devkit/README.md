# debinstall 开发者工具包（devkit）

把 Arch Linux 上的自研工具 **debinstall**（把外来 `.deb` 转成真正的 pacman 包再安装）
的**完整逻辑、源码与测试**打包在这里，供其他 AI / 其他会话接手继续开发。

版本：**2.0.1**

---

## 从哪开始

| 你是 | 先读 |
|---|---|
| 想快速让另一个 AI 接手 | `AI-PROMPT.md` —— 直接复制粘贴的引导语 |
| 要理解逻辑 | `DESIGN.md` —— 10 章逻辑说明书 |
| 要查具体东西 | `REFERENCE.md` —— 命令行/函数/格式/正则速查 |
| 要开始改代码 | `HANDOFF.md` —— 环境、测试、改动配方、禁忌 |

## 目录

```
devkit/
├── README.md        本文件
├── AI-PROMPT.md     给其他 AI 的引导语（可粘贴）
├── DESIGN.md        逻辑说明书（权威）
├── REFERENCE.md     速查表
├── HANDOFF.md       接手手册
├── src/             源码快照（2.0.1，只读参考）
└── test/
    ├── make-test-debs.sh   造 7 个测试 .deb（含恶意样例）
    └── run-checks.sh       110 项回归检查（安全，不真装东西）
```

## 一句话上手

```bash
test/make-test-debs.sh      # 造测试包 → /tmp/debtest/
test/run-checks.sh          # 跑回归（基线 110/110 全过）
```

## 三条铁律

1. **默认只读** —— 不带 `--install` / `-l` 绝不写系统。
2. **输出文案即 GUI 接口** —— 改引擎 stdout 前先读 `DESIGN.md` 第 7 章。
3. **以 root 处理不可信输入** —— 改动取向是更保守，不是更方便。

> 运行时真正生效的代码在 `~/.local/bin/`；`src/` 只是快照，`packaging/` 是打包中转。
> 改代码改前者。
