# Mews: App Store 付费前产品化设计

## 一句话定位

Mews 是一个给 CLI AI 用户用的本地 macOS 小工具。它盯着终端里的 AI agent，在任务完成、失败、等待权限或需要你输入时，用菜单栏和通知提醒你。

英文定位：

> Mews keeps an eye on your terminal AI agents, so you do not have to.

## 现阶段判断

Mews 适合先做开源项目，通过 Homebrew 分发。第一批用户本来就习惯命令行、GitHub 和可审计工具，`brew install mews` 比 App Store 更符合他们的信任路径。

App Store 付费版应该晚一点再做。开源版先证明痛点真实、接入方式稳定、用户愿意长期挂着它。付费版卖体验层，不卖基础 notify 能力。

## 目标用户

### 核心用户

每天在 macOS 终端里跑 AI coding agents 的开发者：

- Claude Code 用户
- Codex CLI 用户
- Copilot CLI 用户
- tmux 重度用户
- 同时开多个 terminal pane，让 agent 后台跑测试、改代码或等待权限的人

### 次级用户

喜欢本地小工具的 macOS power users。他们不想打开一个 AI dashboard，只想要一个可靠、低打扰、能脚本化的状态提醒器。

## 用户痛点

1. AI agent 经常在 tmux 或后台终端里运行，完成后用户不知道。
2. 失败、卡住、等待权限和等待输入的状态在终端外不可见。
3. 多个 agent 并行时，很难知道哪个项目需要处理。
4. 系统通知太一次性，错过后没有轻量状态记录。
5. 现有 Notch 或菜单栏工具不是面向 AI agent 生命周期设计的。

## 产品做什么

第一阶段只做一件事：把终端 AI agent 的状态变成低打扰、可感知的本地提醒。

能力范围：

- 接收 CLI、hook、wrapper 或脚本发来的本地事件。
- 在 macOS 菜单栏显示当前状态。
- 保留最近几条事件历史。
- 支持系统通知和声音。
- 提供 Claude Code、Codex、Copilot CLI 的接入示例。
- 提供 `mews run -- <command>`，让没有 hook 的 CLI 也能被包一层。
- 默认不上传、不同步、不读取完整 transcript。

## 产品不做什么

- 不做 AI 聊天客户端。
- 不替代 Claude Code、Codex 或 Copilot CLI。
- 不读取用户完整代码、完整对话或 terminal scrollback。
- 不做云同步。
- 不做团队监控。
- 不做通用日志分析平台。
- 不做完整 NotchNook 替代品。
- 第一阶段不承诺自动识别所有 terminal 状态。

## 开源版和付费版边界

### 开源版

开源版解决专业用户的基础刚需，让 Mews 成为一个可信、可集成、可脚本化的小工具。

包含：

- `mews notify`
- `mews run`
- 本地 daemon
- 菜单栏状态
- 最近事件列表
- Claude Code hook 示例
- Codex notify 示例
- Copilot CLI wrapper 示例
- Homebrew formula
- 本地隐私说明

不放入开源版核心承诺：

- 精致刘海小猫动画
- 多主题
- 自动安装所有 hooks
- 图形化 onboarding
- 多 agent 高级聚合视图
- 长期历史和筛选

### App Store 付费版

付费版卖的是 macOS 体验，不是 notify 协议本身。

可能包含：

- 刘海小猫动画
- 多 agent 会话面板
- 自动 hook 安装器
- 图形化配置
- 状态历史和筛选
- 主题、声音和动作包
- 外接显示器策略
- 更好的失败、等待权限、等待输入聚合提醒
- 一键导出诊断报告

## MVP 范围

MVP 只需要证明“我不会再错过 AI agent 状态”。

必须有：

1. `mews notify --source claude-code --status done --project Mews --message "Task finished"`
2. `mews run -- copilot`
3. 菜单栏显示最后一个状态。
4. 菜单栏下拉展示最近 5 条事件。
5. Claude Code hooks 配置示例。
6. Codex notify 配置示例。
7. Copilot CLI wrapper 使用说明。
8. `brew install mews` 安装路径。

可以没有：

1. 刘海动画。
2. App Store 版本。
3. 图形化设置页。
4. 自动扫描 tmux。
5. 移动端推送。

## 状态模型

Mews 第一阶段只处理 5 个状态：

| 状态 | 含义 | UI 表达 |
|---|---|---|
| `running` | agent 正在工作 | 菜单栏显示运行态 |
| `needs_input` | 等待用户输入、权限或确认 | 强提醒 |
| `done` | 任务完成 | 温和通知 |
| `failed` | 任务失败或命令异常退出 | 明显失败态 |
| `idle` | 没有活跃任务 | 安静待机 |

事件字段保持克制：

```json
{
  "source": "claude-code",
  "session_id": "abc123",
  "project": "Mews",
  "status": "done",
  "message": "Task finished",
  "timestamp": "2026-07-07T18:40:00+08:00"
}
```

## 交互原则

1. 默认安静。只有失败、等待输入和任务完成才打扰用户。
2. 菜单栏永远可靠。刘海和动画只是增强层。
3. 用户必须明确接入。不要偷偷读 terminal 输出。
4. 错过通知后，用户可以从菜单栏找回最近状态。
5. 状态超过一段时间没有更新时自动回到 idle，避免永久卡在 running。

## 安装和分发

第一阶段推荐路径：

```bash
brew install mews
mews start
mews notify --status done --message "Hello"
```

后续可以提供：

```bash
brew services start mews
mews doctor
mews hook install claude-code
```

Homebrew 是主分发渠道，GitHub Releases 提供二进制。App Store 只在产品信号足够强后启动。

## 首屏 README 文案

```text
Mews

Never miss your AI agents again.

A tiny local macOS companion for Claude Code, Codex, Copilot CLI, and terminal-first AI workflows.
```

## 成功信号

进入 App Store 付费前，至少要看到这些信号：

1. 有持续的 GitHub stars 和 Homebrew 安装量。
2. 有用户主动提交 Claude Code、Codex、Copilot CLI 以外的接入方式。
3. issue 里有人要求更好的 UI、自动配置、历史记录或多 agent 聚合。
4. 用户愿意把它设为登录启动项。
5. 用户反馈“以前会错过，现在不会了”。

## 不适合收费的部分

这些能力应该保持开源免费：

- 基础事件协议。
- CLI notify 命令。
- wrapper 机制。
- Claude Code、Codex、Copilot CLI 的基本接入示例。
- 本地菜单栏基础状态。

原因很简单：这些是建立信任和生态的地基。如果把地基收费，第一批专业用户不会帮它传播。

## 适合收费的部分

这些能力更适合作为 App Store 版：

- 刘海小猫和动画细节。
- 更好的多会话 UI。
- 自动安装和修复 hooks。
- 更完整的设置面板。
- 主题和声音。
- 状态历史、筛选和项目分组。
- 更好的外接显示器体验。

用户为这些付费，是因为它省心、好看、长期陪伴，而不是因为它能发一条通知。

## 产品风险

### 风险 1：Copilot CLI 没有稳定 hooks

处理方式：第一阶段把 Copilot CLI 定位为 wrapper 接入，不承诺深度原生集成。

### 风险 2：刘海动画过早消耗精力

处理方式：开源 MVP 先把菜单栏和事件链路做稳。刘海小猫作为 App Store 体验层，不作为开源 MVP 的成败标准。

### 风险 3：用户担心隐私

处理方式：协议只接收显式事件，默认不读 transcript、不读代码、不上传。README 第一屏要写清楚 local-only。

### 风险 4：状态误判

处理方式：第一阶段不做自动终端分析，优先使用 hooks、wrapper 和用户显式事件。

## 推荐路线

先做开源版 Mews，目标是成为 AI CLI 用户的本地状态提醒基础设施。

当开源版验证出稳定需求，再做 Mews for Mac。付费版不要改变开源版定位，而是提供更好的 macOS companion 体验。

最重要的产品边界是：Mews 不要变成 AI 工作台。它应该一直是一个安静、可信、低打扰的小工具。
