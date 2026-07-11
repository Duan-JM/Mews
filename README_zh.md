<div align="center">
  <h1>Mews</h1>
  <p><em>🐈 不再错过你的 AI agent。</em></p>
</div>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-local--first-black?style=flat-square" alt="macOS local first">
  <img src="https://img.shields.io/badge/distribution-signed_release_pipeline-orange?style=flat-square" alt="Signed release pipeline">
  <img src="https://img.shields.io/badge/license-GPL_v3-blue.svg?style=flat-square" alt="License">
  <img src="https://img.shields.io/badge/status-MVP_release_candidate-green?style=flat-square" alt="MVP release candidate">
</p>

[English](./README.md)

Mews 会盯着你在终端里运行的 AI agent，把它们的生命周期事件留在本机，让你不用一直切回终端看状态。

当 Claude Code、Codex、Copilot CLI 或一个长时间运行的终端命令完成、失败或需要你处理时，Mews 会提醒你。

> Mews 目前是 MVP release candidate。本地产品链路、三种 agent 接入、可逆 setup、安装包验证，以及签名和公证发布流程已经实现。Homebrew tap 仍是后续分发工作。

## 安装

从 GitHub release 安装：

```bash
tar -xzf mews-vX.Y.Z-darwin.tar.gz
cd mews-vX.Y.Z-darwin
sudo ./install.sh
mw setup
mw setup --yes
mw start
```

安装前请用 release 附带的 `.sha256` 文件校验压缩包。

从仓库开发和体验：

```bash
make build
./bin/mw setup
./bin/mw setup --yes
./bin/mw start
./bin/mw doctor
```

`mw setup` 会先展示 Mews 准备写入的本地改动。`mw setup --yes` 才会应用这些 Mews-owned 设置。`mw start` 会安装当前用户的 LaunchAgent，并启动由 `make build` 打包出来的轻量菜单栏 companion。

默认通知会带上安全上下文，比如工具、状态、项目名、工作目录，以及工具提供的 session id。如果你希望通知里带一个简短任务标题，需要显式开启：

```bash
mw setup --yes --include-task-title
```

这个选项最多保存 80 个来自 hook payload 的本地字符。Mews 仍然不会上传 prompt、transcript 或终端输出。

Setup 会安装：

- Claude Code 生命周期 hook：`~/.claude/settings.json`
- Codex 顶层 `notify` 命令：`~/.codex/config.toml`
- Copilot CLI user-level hook：`~/.copilot/hooks/mews.json`

Mews 修改 Claude 和 Codex 配置前会创建备份，保留无关设置，并把管理路径记录到 `integrations.json`。遇到冲突或无法安全处理的配置结构时会拒绝修改。setup 后需要重启对应 CLI，让它重新加载配置。

如果某个接入不能安全启用，Mews 会跳过它，并在 `mw doctor` 里说明原因。

## 为什么做

AI agent 很容易启动，也很容易被忘掉。

你让 Claude Code 改一个文件，让 Codex 跑测试，或者让 Copilot CLI 处理一段任务，然后切去做别的事。十分钟后它可能已经完成、失败、卡住或在等你确认，但信号还埋在某个终端窗口里。

Mews 把这些隐藏状态变成本地、低打扰的提醒。

## MVP 已有能力

- 完成、失败和需要输入时发送原生 macOS 通知。
- 本地 JSONL 历史记录，错过通知后还能找回。
- 菜单栏 companion 会显示最新本地状态和最近事件。
- `doctor` 会显示 setup、三种接入、通知权限、LaunchAgent、socket 和菜单栏 app 状态。
- 本地事件日志有容量上限，发布包带隔离 smoke test。

## Mac companion

当前菜单栏 companion 故意保持轻量。它会启动本地 IPC agent，读取本地事件历史，并把最新状态留在菜单栏里。

之后的 **Mews for Mac** 可以加入刘海小猫：agent 运行时小猫走动，空闲时睡觉，完成时跳一下，需要你处理时吸引注意。

## Mews 监控什么

Mews 面向终端 AI 用户已经在用的工具：

- Claude Code：通过 user-level 生命周期 hook 接入
- Codex：通过 user-level `notify` 命令接入
- Copilot CLI：通过 user-level hook 接入
- 长时间运行的 shell 命令：使用 `mw run -- <command>`

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
mw reset --yes # undo 后删除 Mews 本地数据和日志
```

## Mews 不是什么

Mews 不是 AI 聊天应用，不是 Claude wrapper，不是 Codex dashboard，不是 Copilot 替代品，也不是团队监控产品。

它只是一个给终端 AI agent 用户用的小型 Mac companion，让你不用一直盯着终端。

## 发布

维护者在 macOS 上生成签名发布包：

```bash
VERSION=vX.Y.Z \
SIGN_IDENTITY="Developer ID Application: ..." \
NOTARY_PROFILE=mews-notary \
make release
```

发布命令强制要求签名和公证凭证，使用 Gatekeeper 校验 App，并生成 tarball、SHA-256 校验文件，以及用于发布到 Homebrew tap 的版本固定 `dist/mews.rb` formula。缺少凭证时不会生成形式上像正式发布、实际未签名的产物。

## 路线图

- 发布并维护 Homebrew tap。
- 增加 quiet mode 和更细的通知规则。
- 改进菜单栏视觉，但不扩张为 agent dashboard。

## 产品说明

更长的设计说明在 [docs/](./docs/)。
