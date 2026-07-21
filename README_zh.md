<div align="center">
  <img src="./assets/mews-logo.svg" width="96" height="96" alt="Mews 极简猫咪 logo">
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
make lint-tools
make check
./bin/mw setup
./bin/mw setup --yes
./bin/mw start
./bin/mw doctor
```

`mw setup` 会先展示 Mews 准备写入的本地改动。`mw setup --yes` 才会应用这些 Mews-owned 设置。`mw start` 会安装当前用户的 LaunchAgent，并启动由 `make build` 打包出来的轻量菜单栏 companion。

终端返回默认使用 `auto`：能识别事件来源时回到原终端，否则使用 Terminal.app。可以在 setup 时指定，也可以之后修改：

```bash
mw setup --yes --terminal kitty
mw config terminal kitty
```

可选项包括 `auto`、`terminal`、`kitty`、`iterm2`、`wezterm`、`ghostty` 和 `alacritty`。`mw status` 与 `mw config terminal` 会显示当前设置。

主 session 每次进入完成、失败或需要输入状态时，Mews.app 只选择一个提醒通道。同一轮状态的重复 hook、日志重放或轮转、App 重启不会再次提醒；session 回到 `running` 或 `idle` 后，后续的新一轮状态仍会提醒。有可用实体刘海时，由刘海状态层展示状态变化，不再同时发送 macOS 通知；合盖、无刘海屏幕或暂时没有可用屏幕时，Notification Center 继续作为降级通道。Subagent 完成和可恢复错误只进入本地历史，不会替换主状态或打断用户。降级通知的标题会标明 agent 和状态，并在工具提供相关信息时显示项目名和缩短后的 session id。正文会描述生命周期动作，但不会展示完整工作目录、完整 session id、prompt 或终端输出。如果希望正文带一个简短任务标题，需要显式开启：

```bash
mw setup --yes --include-task-title
```

这个选项最多保存 80 个来自 hook payload 的本地字符。Mews 仍然不会上传 prompt、transcript 或终端输出。

App bundle 会带上 Mews 猫咪 logo 作为 macOS 图标。原生降级通知使用这个 App 身份，不会把 logo 作为通知内容额外塞进去。事件带有可用本地上下文时，通知会提供 **Return to CLI** 和 **Copy Return Command**。通过通知、状态层或 session 菜单返回时，只确认该 session 当前的注意力；复制返回命令不会确认。返回时会先复制 Mews 生成的 `mw history --session 'abc123'`，再优先激活原终端；有 tmux 上下文时会把记录的 client 切回原 session、window 和 pane。如果原 client 已 detached，但 tmux server 和 pane 仍存在，Mews 会新开 kitty 窗口并直接 attach 到记录的 pane。kitty 已配置本地 Unix remote-control socket 时还会尝试聚焦原窗口。无法恢复原 kitty 或 detached tmux 上下文时，即使 kitty 已经在运行，Mews 也会在经过校验的工作目录打开并激活一个新窗口。其他终端的原上下文不可用时，会用选定终端打开该目录。Mews 不修改 kitty 配置，不执行事件传入的命令，也不读取 terminal scrollback。

Setup 会安装：

- Claude Code 生命周期 hook：`~/.claude/settings.json`
- Codex 顶层 `notify` 命令：`~/.codex/config.toml`
- Copilot CLI user-level hook：`~/.copilot/hooks/mews.json`

Mews 修改 Claude 和 Codex 配置前会创建备份，保留无关设置，并把管理路径记录到 `integrations.json`。遇到冲突或无法安全处理的配置结构时会拒绝修改。setup 后需要重启对应 CLI，让它重新加载配置。

如果某个接入不能安全启用，Mews 会跳过它，并在 `mw doctor` 里说明原因。

## 运行健康状态

`mw status`、`mw doctor` 和原生 companion 读取同一份本地 runtime-health snapshot。`checking`、`ready` 与过期数据不会占用菜单和展开面板；只有新鲜的 `degraded` 或 `blocked` 能力会显示受影响项、简短原因，以及可复制的恢复指令。配置漂移与 IPC 功能故障保持分开，恢复动作不会自动修改第三方配置。

## 为什么做

AI agent 很容易启动，也很容易被忘掉。

你让 Claude Code 改一个文件，让 Codex 跑测试，或者让 Copilot CLI 处理一段任务，然后切去做别的事。十分钟后它可能已经完成、失败、卡住或在等你确认，但信号还埋在某个终端窗口里。

Mews 把这些隐藏状态变成本地、低打扰的提醒。

## MVP 已有能力

- 主 agent 需要关注时，只使用实体刘海提示或原生 macOS 通知降级中的一个通道。
- 本地 JSONL 历史记录，错过通知后还能找回。
- 菜单栏 companion 使用随状态变化的像素 Logo、按操作优先级排列的近期 session，以及紧凑的刘海/顶部居中状态层。
- `doctor` 会显示 setup、三种接入、通知权限、LaunchAgent、socket 和菜单栏 app 状态。
- 本地事件日志有容量上限，发布包带隔离 smoke test。

## Mac companion

当前菜单栏 companion 故意保持轻量。它会启动本地 IPC agent，读取本地事件历史与可恢复 session 状态，并通过紧凑的像素 Logo 显示最新状态。左键点击 Logo 会打开贴合实体刘海或其他屏幕顶部居中的小型状态层；右键或 Control-click 会打开按优先级排列的 session、无稳定 session id 的历史事件、Refresh 和 Quit 菜单。

状态层会跟随屏幕拓扑变化，不会沿用过期坐标。有实体刘海时，顶部窄颈贴合硬件，刘海下方固定显示像素小猫与 `IDLE`、`RUN`、`ASK`、`DONE` 或 `FAIL`。需要输入、完成和失败事件会短暂加宽状态条并显示直白说明，随后收回紧凑形态；点击可见区域会从同一锚点展开现有面板。合盖模式或只连接外接屏时，状态层会落在主屏菜单栏下方；短暂没有可用屏幕时先隐藏，屏幕恢复后重新定位。提醒通道也使用当前拓扑：实体刘海可用时由刘海状态层提示，其他布局使用 Notification Center，不会自动展开顶部居中面板。面板可跨 Space，并能显示在全屏辅助层。开启“减弱动态效果”后，尺寸变化改为静态切换和短淡入淡出；开启“增强对比度”后，次要文字与边界会更清楚；VoiceOver 可以读出明确的状态和面板标签。

当前状态有固定时效，但本地历史不会被删除。`running` 与 `needs_input` 最多保留 24 小时，`done` 与 `failed` 保留 30 分钟。注意力过期后会解除，并在 Notification Center 允许时移除对应通知。超过时限后，Logo 和当前摘要回到 `idle`；最近 24 小时内仍可恢复的 session 会继续出现在 session 列表里。App 会复用已经在运行的本地 agent，不会重复启动，也不会在退出时终止外部进程。内置 agent 退出或暂时不可用时，重试间隔会从 10 秒逐步增加，最长 5 分钟，不会跟着两秒一次的历史刷新持续拉起进程。

展开后的状态层最多显示三个 session，顺序依次为 `needs_input`、`failed`、未确认的 `done`、`running`，再到已确认或空闲的近期 session。每行显示 agent、受限项目名、缩短后的 session id、状态，以及各自的 **Return** 与 **Copy**。展开期间行顺序和健康状态操作保持固定，刷新不会把鼠标下方的目标换走。没有稳定 session id 的事件继续作为受限历史显示，不会伪造成 session。完整 session id、工作目录、subagent 事件、可恢复失败、prompt 文本和 `mw run` 命令文本不会出现在面板里。操作只使用经过校验的本地上下文和 Mews 生成的历史命令；上下文不可用时按钮保持禁用。

现在的单色像素小猫会在空闲时睡觉、agent 运行时工作、需要输入时提醒，并在完成或失败时播放一次短动作。

### 合成界面预览

第一张合成预览展示像素小猫与 `IDLE`、`RUN`、`ASK`、`DONE`、`FAIL` 五种紧凑刘海状态。

![Mews 合成紧凑刘海状态，包含像素小猫以及 IDLE、RUN、ASK、DONE、FAIL 标签](assets/screenshots/mews-status-states.png)

多 session 合成面板展示 `needs_input`、`failed`、`done` 三种 session。安全的本地上下文会启用 **Return** 与 **Copy**，上下文不可用时两个按钮保持明显的禁用状态。

![Mews 合成展开面板，包含 needs-input、failed、done session，以及启用和禁用的 Return、Copy 按钮](assets/screenshots/mews-multi-session.png)

降级健康状态合成面板展示 event delivery 警告、**Copy Fix**、可操作的 running session，以及按钮禁用的 idle session。

![Mews 合成展开面板，包含降级的 event-delivery 健康状态、Copy Fix、可操作的 running session 和按钮禁用的 idle session](assets/screenshots/mews-degraded-health.png)

贡献者可运行 `make screenshots` 重新生成三张固定尺寸图片。开发专用 fixture 不会渲染本地事件历史、prompt、终端输出、用户名、HOME 路径或真实、冗长的 session id。

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
mw setup --yes --terminal kitty # setup 时指定返回终端
mw setup --yes --include-task-title # 显式开启本地短任务标题
mw start       # setup 后启动本地 agent
mw status      # 查看当前本地状态
mw config terminal kitty # 修改返回终端
mw history     # 查看最近本地事件
mw history --session <id> # 查看某个 session 的事件
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

维护者可以先运行不需要签名凭据的发布检查：

```bash
VERSION=vX.Y.Z make release-check
```

正式发布需要在与 `origin/main` 同步的干净 `main` 分支上运行：

```bash
VERSION=vX.Y.Z \
SIGN_IDENTITY="Developer ID Application: ..." \
NOTARY_PROFILE=mews-notary \
make release
```

`make release-check` 会运行测试、lint、安装包校验和检查，以及隔离的安装后运行 smoke，不需要签名凭据。正式发布命令强制要求签名和公证凭据，使用 Gatekeeper 校验 App，并生成 tarball、SHA-256 校验文件，以及用于发布到 Homebrew tap 的版本固定 `dist/mews.rb` formula。缺少凭据时不会生成形式上像正式发布、实际未签名的产物。

## 路线图

- 发布并维护 Homebrew tap。
- 增加 quiet mode 和更细的通知规则。
- 改进菜单栏视觉，但不扩张为 agent dashboard。

## 产品说明

更长的设计说明在 [docs/](./docs/)。
