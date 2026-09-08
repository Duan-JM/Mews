<div align="center">
  <img src="./assets/mews-logo.svg" width="96" height="96" alt="Mews cat logo">
  <h1>Mews</h1>
  <p><em>Never miss your terminal AI agents.</em></p>
</div>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-local--only-black?style=flat-square" alt="macOS local only">
  <img src="https://img.shields.io/badge/status-preflight-orange?style=flat-square" alt="Preflight release">
  <img src="https://img.shields.io/badge/license-GPL_v3-blue.svg?style=flat-square" alt="GPL v3 license">
</p>

[简体中文](./README_zh.md)

Mews is a local macOS menu bar companion for AI coding agents running in terminals. It lets you know when an agent finishes, fails, or needs input, so you do not have to keep checking every terminal pane.

## Features

- Uses a quiet green or red glow around the MacBook notch for current agent state, with Notification Center as the fallback.
- Shows current sessions in the menu bar and keeps recent event history on your Mac.
- Supports Claude Code, Codex, Copilot CLI, and long-running commands through `mw run`.
- Returns to a validated source terminal when possible, opens confirmed Codex App sessions directly, and can copy a command for local history.

## Interface previews

![Synthetic Mews notch glows for idle, running, needs-input, done, and failed states](assets/screenshots/mews-status-states.png)

![Synthetic Mews active sessions panel](assets/screenshots/mews-multi-session.png)

![Synthetic Mews degraded health panel](assets/screenshots/mews-degraded-health.png)

## Install

Install the current public preflight with Homebrew:

```bash
brew install --cask duan-jm/mews/mews
xattr -dr com.apple.quarantine /Applications/Mews.app

mw setup
mw setup --yes
mw start
```

To install without Homebrew, download the archive and its `.sha256` file from
[GitHub Releases](https://github.com/Duan-JM/Mews/releases), then run:

```bash
shasum -a 256 -c mews-vX.Y.Z-darwin.tar.gz.sha256
tar -xzf mews-vX.Y.Z-darwin.tar.gz
cd mews-vX.Y.Z-darwin
sudo ./install.sh

mw setup
mw setup --yes
mw start
```

`mw setup` previews the local configuration changes. `mw setup --yes` applies them, and `mw start` launches the menu bar app.

### Upgrade

Preflight builds are ad-hoc signed. Review the GitHub Release and checksum, then
remove quarantine after every installation or upgrade.

```bash
mw stop
brew update
brew upgrade --cask mews
xattr -dr com.apple.quarantine /Applications/Mews.app
mw start
```

### Install a development build with Homebrew

Development builds use the current `dev` branch and a local Homebrew tap. They are ad-hoc signed and intended only for local testing.

For the first installation:

```bash
git clone --branch dev https://github.com/Duan-JM/Mews.git
cd Mews
make cask-local
brew install --cask duan-jm/mews-local/mews@dev

mw setup
mw setup --yes
mw start
```

To rebuild and install the latest `dev` branch:

```bash
mw stop
git switch dev
git pull --ff-only origin dev
make cask-local
brew reinstall --cask duan-jm/mews-local/mews@dev
mw start
```

## Uninstall

Remove Mews-owned integrations before deleting the installed files:

```bash
mw undo

# Optional: delete local event history and logs.
mw reset --yes

brew uninstall --cask duan-jm/mews/mews
```

For an archive installation, remove the installed files instead:

```bash
sudo rm -f /usr/local/bin/mw
sudo rm -rf /usr/local/libexec/Mews.app
```

Skip `mw reset --yes` if you want to keep local history. If you installed with a custom `PREFIX`, replace `/usr/local` with that prefix.

## Security & Safety Design

- Core features run locally without an account, telemetry, or cloud service.
- Mews does not read or upload code, prompts, transcripts, command output, or terminal scrollback by default.
- Setup previews planned writes, backs up supported configuration files, and leaves files unchanged when it cannot edit them safely.
- `mw undo` removes Mews-owned integration changes without deleting unrelated user configuration.
- Task titles are opt-in, truncated, and stored locally. Return actions use validated local context and never execute command text received from an event.

See the [Security Policy](./SECURITY.md) for reporting and trust boundaries.

## Tips

- Run `mw status` for a quick view of watched tools and current state.
- Run `mw doctor` when an integration, notification, or the menu bar app is not working.
- Use `mw history` to review recent events, or `mw history --session <id>` for one session.
- Use `mw config terminal <name>` to choose where return actions open.
- Wrap any long command with `mw run -- <command>` to receive a completion notification.
- Add `--include-task-title` to `mw setup --yes` only if you want short task labels stored locally.

## Documentation

Architecture, product design, interface previews, packaging, release, and rollback details live in the [documentation index](./docs/README.md). Release history is in [CHANGELOG.md](./CHANGELOG.md), and contributor setup is in [CONTRIBUTING.md](./CONTRIBUTING.md).

Mews is licensed under [GPL v3](./LICENSE).
