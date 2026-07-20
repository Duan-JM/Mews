<div align="center">
  <img src="./assets/mews-logo.svg" width="96" height="96" alt="Mews minimal cat logo">
  <h1>Mews</h1>
  <p><em>🐈 Never miss your AI agents again.</em></p>
</div>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-local--first-black?style=flat-square" alt="macOS local first">
  <img src="https://img.shields.io/badge/distribution-signed_release_pipeline-orange?style=flat-square" alt="Signed release pipeline">
  <img src="https://img.shields.io/badge/license-GPL_v3-blue.svg?style=flat-square" alt="License">
  <img src="https://img.shields.io/badge/status-MVP_release_candidate-green?style=flat-square" alt="MVP release candidate">
</p>

[简体中文](./README_zh.md)

Mews watches the AI agents you run from terminal and keeps their lifecycle events visible locally.

When Claude Code, Codex, Copilot CLI, or a long-running terminal command finishes, fails, or needs you, Mews lets you know. You do not have to keep checking every pane.

> Mews is an MVP release candidate. The local product path, three agent integrations, reversible setup, package verification, and signed/notarized release pipeline are implemented. A Homebrew tap is still a distribution follow-up.

## Install

From a GitHub release artifact:

```bash
tar -xzf mews-vX.Y.Z-darwin.tar.gz
cd mews-vX.Y.Z-darwin
sudo ./install.sh
mw setup
mw setup --yes
mw start
```

Verify the downloaded archive with the adjacent `.sha256` file before installing.

For development from this repository:

```bash
make lint-tools
make check
./bin/mw setup
./bin/mw setup --yes
./bin/mw start
./bin/mw doctor
```

`mw setup` shows the local changes Mews wants to make before it writes anything. `mw setup --yes` applies the Mews-owned setup. `mw start` installs a per-user LaunchAgent and starts the thin menu bar companion packaged by `make build`.

Terminal return uses `auto` by default: Mews returns to the terminal that emitted the event when it can identify it, with Terminal.app as the fallback. Choose a terminal during setup or change it later:

```bash
mw setup --yes --terminal kitty
mw config terminal kitty
```

Supported profiles are `auto`, `terminal`, `kitty`, `iterm2`, `wezterm`, `ghostty`, and `alacritty`. `mw status` and `mw config terminal` show the current preference.

Mews.app delivers notifications through the native macOS notification center for primary-agent completion, failure, and input-needed states. Subagent completions and recoverable errors stay in local history without replacing the primary menu bar state or interrupting you. Notifications identify the agent and status in the title, then show the project and a shortened session identifier when the tool provides them. The body describes the lifecycle action without exposing the full working directory, full session identifier, prompt, or terminal output. To show a short task label in the body, opt in explicitly:

```bash
mw setup --yes --include-task-title
```

That stores at most 80 local-only characters from a hook-provided prompt or title. Mews still does not upload prompts, transcripts, or terminal output.

The app bundle includes the Mews cat logo as its macOS icon. Native notifications use that app identity instead of adding the logo as notification content. Notifications expose **Return to CLI** and **Copy Return Command** actions when the event has usable local context. Returning copies a Mews-generated command such as `mw history --session 'abc123'`, then prefers the existing source terminal. Mews switches the recorded tmux client back to the source session, window, and pane when available. If that client has detached but the tmux server and pane still exist, Mews opens a new kitty window and attaches directly to the recorded pane. It can also focus a kitty window when kitty already exposes a local Unix remote-control socket. If an exact kitty or detached tmux context cannot be restored, Mews opens and activates a new kitty window at the validated event working directory even when kitty is already running. Other terminal profiles use the configured terminal at that directory when their source context is unavailable. Mews never changes kitty configuration, executes command text supplied by an event, or reads terminal scrollback.

Setup installs:

- Claude Code lifecycle hooks in `~/.claude/settings.json`.
- Codex's top-level `notify` command in `~/.codex/config.toml`.
- Copilot CLI user-level hooks in `~/.copilot/hooks/mews.json`.

Existing Claude and Codex files are backed up before editing. Mews preserves unrelated settings, refuses conflicting or malformed structures it cannot edit safely, and records every managed path in `integrations.json`. Restart the agent CLIs after setup so they reload their configuration.

If something cannot be enabled safely, Mews leaves it alone and explains the fix in `mw doctor`.

## Why

AI agents are easy to start and easy to forget.

You ask Claude Code to refactor a file, leave Codex running tests, or let Copilot CLI work through a command. Then you switch apps. Ten minutes later the agent may be done, stuck, or waiting for permission, but the only signal is buried in a terminal pane.

Mews turns that hidden state into a small local signal.

## MVP

- Native macOS notifications for primary-agent completion, failure, and input-needed events.
- A local JSONL history so missed notifications are not gone forever.
- A menu bar companion that shows the latest local state and recent events.
- Clear doctor output for setup, all integrations, notification permission, LaunchAgent, socket, and the menu bar app.
- Bounded local event history and an isolated package smoke test.

## Mac Companion

The current menu bar companion is intentionally thin. It starts the local IPC agent, reads the local event history, and keeps the latest state visible from the menu bar.

Later, **Mews for Mac** can add the notch cat: a small cat around the MacBook notch that walks while agents run, naps when idle, pounces when something finishes, and gets your attention when a prompt is waiting.

## What Mews Watches

Mews should work out of the box with the tools terminal AI users already have:

- Claude Code through user-level lifecycle hooks
- Codex through its user-level `notify` command
- Copilot CLI through user-level hooks
- long-running shell commands through `mw run -- <command>`

You should not need to copy hook JSON, edit config files, or learn a notification protocol before Mews becomes useful.

## Privacy

Mews should be boringly private.

- It runs locally on your Mac.
- It does not upload code, prompts, transcripts, or terminal output.
- It does not scan terminal scrollback by default.
- It only enables integrations you approve.
- Every automatic change should be reversible.

## Commands

Most users should only need these commands:

```bash
mw setup       # Show the setup plan
mw setup --yes # Apply Mews-owned setup
mw setup --yes --terminal kitty # Set the return terminal during setup
mw setup --yes --include-task-title # Opt in to short local task labels
mw start       # Start the local agent after setup
mw status      # Show the current local state
mw config terminal kitty # Change the return terminal
mw history     # Show recent local events
mw history --session <id> # Show events for one session reference
mw listen      # Listen in the terminal and print events as they arrive
mw doctor      # Diagnose setup, integrations, LaunchAgent, and IPC
mw undo        # Remove Mews-installed integrations and setup state
```

For people who want to script Mews directly:

```bash
mw notify      # Send a custom status event
mw run -- cmd  # Run a command and notify when it exits
mw stop        # Stop the local agent
mw reset --yes # After undo, delete local Mews data and logs
```

## What Mews Is Not

Mews is not an AI chat app, not a Claude wrapper, not a Codex dashboard, not a Copilot replacement, and not a team monitoring product.

It is a small Mac companion for people who run AI agents in terminals and do not want to babysit them.

## Release

Maintainers create a signed release artifact on macOS:

```bash
VERSION=vX.Y.Z make release-check

VERSION=vX.Y.Z \
SIGN_IDENTITY="Developer ID Application: ..." \
NOTARY_PROFILE=mews-notary \
make release
```

`make release-check` runs tests, lint, package checksum verification, and an isolated installed-runtime smoke without requiring signing credentials. The formal release command must run from a clean `main` synchronized with `origin/main`; it requires signing and notarization credentials, verifies the app with Gatekeeper, and produces a tarball, SHA-256 checksum, and version-pinned `dist/mews.rb` formula for publication to a Homebrew tap. It fails instead of producing an unsigned formal release.

## Roadmap

- Publish and maintain a Homebrew tap.
- Add richer quiet-mode and notification rules.
- Improve menu bar visual polish without expanding into an agent dashboard.

## Product Notes

Longer design notes live under [docs/](./docs/).
