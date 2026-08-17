<div align="center">
  <img src="./assets/mews-logo.svg" width="96" height="96" alt="Mews 猫咪 Logo">
  <h1>Mews</h1>
  <p><em>别再错过终端里的 AI Agent。</em></p>
</div>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-local--only-black?style=flat-square" alt="仅在 macOS 本地运行">
  <img src="https://img.shields.io/badge/status-preflight-orange?style=flat-square" alt="Preflight 版本">
  <img src="https://img.shields.io/badge/license-GPL_v3-blue.svg?style=flat-square" alt="GPL v3 许可证">
</p>

[English](./README.md)

Mews 是一个运行在 macOS 菜单栏的本地小工具，用来查看终端 AI Agent 的状态。Agent 完成、失败或等待输入时，它会及时提醒你，不用反复检查每个终端窗口。

## 基础功能

- MacBook 刘海可用时显示紧凑状态，其他场景使用通知中心。
- 在菜单栏查看当前会话，并在本机保留最近的事件历史。
- 支持 Claude Code、Codex、Copilot CLI，也可以通过 `mw run` 监控长时间运行的命令。
- 本地上下文有效时可以返回原终端，也可以复制查看该会话本地历史的命令。

## 安装

使用 Homebrew 安装当前公开的 preflight 版本：

```bash
brew install --cask duan-jm/mews/mews
xattr -dr com.apple.quarantine /Applications/Mews.app

mw setup
mw setup --yes
mw start
```

不使用 Homebrew 时，从 [GitHub Releases](https://github.com/Duan-JM/Mews/releases)
下载压缩包和对应的 `.sha256` 文件，然后运行：

```bash
shasum -a 256 -c mews-vX.Y.Z-darwin.tar.gz.sha256
tar -xzf mews-vX.Y.Z-darwin.tar.gz
cd mews-vX.Y.Z-darwin
sudo ./install.sh

mw setup
mw setup --yes
mw start
```

`mw setup` 会先展示计划修改的本地配置。`mw setup --yes` 应用这些改动，`mw start` 启动菜单栏应用。

### 升级

Preflight 构建使用临时签名。请先核对 GitHub Release 和 checksum，每次安装或升级后移除 quarantine。

```bash
mw stop
brew update
brew upgrade --cask mews
xattr -dr com.apple.quarantine /Applications/Mews.app
mw start
```

### 使用 Homebrew 安装开发版

开发版从当前 `dev` 分支构建，并通过本地 Homebrew tap 安装。构建产物使用临时签名，只适合本机测试。

首次安装：

```bash
git clone --branch dev https://github.com/Duan-JM/Mews.git
cd Mews
make cask-local
brew install --cask duan-jm/mews-local/mews@dev

mw setup
mw setup --yes
mw start
```

拉取并安装最新的 `dev` 分支：

```bash
mw stop
git switch dev
git pull --ff-only origin dev
make cask-local
brew reinstall --cask duan-jm/mews-local/mews@dev
mw start
```

## 卸载

删除安装文件前，先移除 Mews 管理的接入配置：

```bash
mw undo

# 可选：删除本地事件历史和日志。
mw reset --yes

brew uninstall --cask duan-jm/mews/mews
```

使用压缩包安装时，改为删除对应文件：

```bash
sudo rm -f /usr/local/bin/mw
sudo rm -rf /usr/local/libexec/Mews.app
```

想保留本地历史时，请跳过 `mw reset --yes`。如果安装时使用了自定义 `PREFIX`，请把 `/usr/local` 换成对应路径。

## 安全设计

- 核心功能完全在本机运行，不需要账号，不包含遥测，也不依赖云服务。
- Mews 默认不读取或上传代码、提示词、对话记录、命令输出和终端滚动内容。
- `mw setup` 会展示计划写入的内容，为支持的配置文件创建备份；无法安全修改时会保持原文件不变。
- `mw undo` 只移除 Mews 管理的接入改动，不删除用户的其他配置。
- 任务标题需要主动开启，内容会截断并只保存在本机。返回操作只使用经过校验的本地上下文，不执行事件传入的命令。

安全问题的报告方式和完整边界见 [Security Policy](./SECURITY.md)。

## 使用技巧

- 用 `mw status` 快速查看已监控的工具和当前状态。
- 接入、通知或菜单栏应用异常时，运行 `mw doctor`。
- 用 `mw history` 查看最近事件，或用 `mw history --session <id>` 查看单个会话。
- 用 `mw config terminal <name>` 选择返回操作打开的终端。
- 在长命令前加 `mw run -- <command>`，命令结束时会收到提醒。
- 只有需要在本机保存简短任务标题时，才为 `mw setup --yes` 添加 `--include-task-title`。

## 文档

架构、产品设计、界面预览、打包、发布和回滚细节见 [文档索引](./docs/README.md)。版本记录见 [CHANGELOG.md](./CHANGELOG.md)，参与开发前请阅读 [CONTRIBUTING.md](./CONTRIBUTING.md)。

Mews 使用 [GPL v3](./LICENSE) 许可证。
