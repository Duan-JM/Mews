<div align="center">
  <h1>Mews</h1>
  <p><em>🐈 不再错过你的 AI agent。</em></p>
</div>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-local--first-black?style=flat-square" alt="macOS local first">
  <img src="https://img.shields.io/badge/Homebrew-planned-orange?style=flat-square" alt="Homebrew planned">
  <img src="https://img.shields.io/badge/license-GPL_v3-blue.svg?style=flat-square" alt="License">
  <img src="https://img.shields.io/badge/status-init--preview-lightgrey?style=flat-square" alt="Init preview">
</p>

[English](./README.md)

Mews 会盯着你在终端里运行的 AI agent，把它们的生命周期事件留在本机，让你不用一直切回终端看状态。

当 Claude Code、Codex、Copilot CLI 或一个长时间运行的终端命令完成、失败或需要你处理时，Mews 会提醒你。

> 仓库目前处于 init preview。`mw` CLI、Copilot hook 接入、本地事件日志、安全命令和一个轻量菜单栏 app 已经可用；更完整的 Mac 分发还在计划中。

## 安装

从仓库本地体验：

```bash
make build
./bin/mw setup
./bin/mw setup --yes
./bin/mw start
./bin/mw doctor
```

Homebrew 会放到第一个公开版本：

```bash
brew install mews
mw setup --yes
mw start
```

`mw setup` 会先展示 Mews 准备写入的本地改动。`mw setup --yes` 才会应用这些 Mews-owned 设置。`mw start` 会安装当前用户的 LaunchAgent，并启动由 `make build` 打包出来的轻量菜单栏 companion。

默认通知会带上安全上下文，比如工具、状态、项目名、工作目录，以及工具提供的 session id。如果你希望通知里带一个简短任务标题，需要显式开启：

```bash
mw setup --yes --include-task-title
```

这个选项最多保存 80 个来自 hook payload 的本地字符。Mews 仍然不会上传 prompt、transcript 或终端输出。

Copilot CLI 的 user-level hook 会安装到 `~/.copilot/hooks/mews.json`。如果设置了 `COPILOT_HOME`，则会安装到 `$COPILOT_HOME/hooks/mews.json`。setup 后需要重新启动 Copilot CLI，让它重新加载 hook 配置。

如果某个接入不能安全启用，Mews 会跳过它，并在 `mw doctor` 里说明原因。

## 为什么做

AI agent 很容易启动，也很容易被忘掉。

你让 Claude Code 改一个文件，让 Codex 跑测试，或者让 Copilot CLI 处理一段任务，然后切去做别的事。十分钟后它可能已经完成、失败、卡住或在等你确认，但信号还埋在某个终端窗口里。

Mews 把这些隐藏状态变成本地、低打扰的提醒。

## 当前预览版有什么

- agent 生命周期事件到达 Mews 时发出简短通知。
- 本地 JSONL 历史记录，错过通知后还能找回。
- 菜单栏 companion 会显示最新本地状态和最近事件。
- `doctor` 会清楚显示 setup、hook、LaunchAgent、socket 和菜单栏 app 是否可用。

## Mac companion

当前菜单栏 companion 故意保持轻量。它会启动本地 IPC agent，读取本地事件历史，并把最新状态留在菜单栏里。

之后的 **Mews for Mac** 可以加入刘海小猫：agent 运行时小猫走动，空闲时睡觉，完成时跳一下，需要你处理时吸引注意。

## Mews 监控什么

Mews 面向终端 AI 用户已经在用的工具：

- Copilot CLI：通过 user-level hooks 接入
- Claude Code 和 Codex：计划通过 hook / notify 接入
- 长时间运行的 shell 命令

用户不应该为了让 Mews 有用，就先学 hook JSON、手动改配置或理解通知协议。

## 隐私

Mews 的隐私边界应该简单、可审计。

- 只在你的 Mac 本机运行。
- 不上传代码、prompt、transcript 或终端输出。
- 默认不扫描 terminal scrollback。
- 只启用你同意的接入。
- 自动写入的改动都应该可以撤销。

## 命令

大多数用户只需要这些命令：

```bash
mw setup       # 查看 setup 计划
mw setup --yes # 应用 Mews-owned setup
mw setup --yes --include-task-title # 显式开启本地短任务标题
mw start       # setup 后启动本地 agent
mw status      # 查看当前本地状态
mw history     # 查看最近本地事件
mw listen      # 在终端里监听并打印事件
mw doctor      # 检查 setup 和接入状态
mw undo        # 移除 Mews 安装的接入和 setup state
```

脚本化场景可以用：

```bash
mw notify      # 发送自定义状态事件
mw run -- cmd  # 运行命令，并在退出时通知
mw stop        # 停止本地 agent
mw reset --yes # 删除 Mews 本地数据和日志
```

## Mews 不是什么

Mews 不是 AI 聊天应用，不是 Claude wrapper，不是 Codex dashboard，不是 Copilot 替代品，也不是团队监控产品。

它只是一个给终端 AI agent 用户用的小型 Mac companion，让你不用一直盯着终端。

## 路线图

### 当前 init preview

- Copilot CLI hook setup
- 本地通知和事件历史
- 菜单栏状态
- Setup doctor、undo 和 reset
- 用于前台调试的终端监听模式
- 本地 agent 和事件管线
- 可脚本化事件通知

### 接下来

- Claude Code 和 Codex 接入
- 每个接入都支持安全撤销
- Homebrew 安装

## 产品说明

更长的设计说明在 [docs/](./docs/)。
