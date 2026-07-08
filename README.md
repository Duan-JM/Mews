<div align="center">
  <h1>Mews</h1>
  <p><em>🐈 Never miss your AI agents again.</em></p>
</div>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-local--first-black?style=flat-square" alt="macOS local first">
  <img src="https://img.shields.io/badge/Homebrew-planned-orange?style=flat-square" alt="Homebrew planned">
  <img src="https://img.shields.io/badge/license-GPL_v3-blue.svg?style=flat-square" alt="License">
  <img src="https://img.shields.io/badge/status-init--preview-lightgrey?style=flat-square" alt="Init preview">
</p>

[简体中文](./README_zh.md)

Mews watches the AI agents you run from terminal and keeps their lifecycle events visible locally.

When Claude Code, Codex, Copilot CLI, or a long-running terminal command finishes, fails, or needs you, Mews lets you know. You do not have to keep checking every pane.

> This repository is in init preview. The `mw` CLI, Copilot hook setup, local event log, and safety commands exist; the menu bar app is still planned.

## Install

For local testing from this repository:

```bash
make build
./bin/mw setup
./bin/mw setup --yes
./bin/mw doctor
```

Homebrew is planned for the first public release:

```bash
brew install mews
mw setup --yes
mw start
```

`mw setup` shows the local changes Mews wants to make before it writes anything. `mw setup --yes` applies the Mews-owned setup. `mw start` is reserved for the planned menu bar companion and currently reports that the app is not packaged yet.

By default, notifications include safe context such as tool, status, project, working directory, and session identifier when the tool provides them. If you want notification titles to include a short task label, opt in explicitly:

```bash
mw setup --yes --include-task-title
```

That stores at most 80 local-only characters from a hook-provided prompt or title. Mews still does not upload prompts, transcripts, or terminal output.

Copilot CLI user-level hooks are installed at `~/.copilot/hooks/mews.json`, or `$COPILOT_HOME/hooks/mews.json` when `COPILOT_HOME` is set. Restart Copilot CLI after setup so it reloads hook configuration.

If something cannot be enabled safely, Mews leaves it alone and explains the fix in `mw doctor`.

## Why

AI agents are easy to start and easy to forget.

You ask Claude Code to refactor a file, leave Codex running tests, or let Copilot CLI work through a command. Then you switch apps. Ten minutes later the agent may be done, stuck, or waiting for permission, but the only signal is buried in a terminal pane.

Mews turns that hidden state into a small local signal.

## Current Preview

- A short notification when an agent lifecycle event reaches Mews.
- A local JSONL history so missed notifications are not gone forever.
- Clear doctor output when setup, hooks, or the planned menu bar agent are missing.

## Planned Mac Companion

- A menu bar icon that shows whether an agent is running, done, failed, or waiting.
- A recent history menu for missed notifications.
- A quiet idle state when nothing is happening.

Later, **Mews for Mac** can add the notch cat: a small cat around the MacBook notch that walks while agents run, naps when idle, pounces when something finishes, and gets your attention when a prompt is waiting.

## What Mews Watches

Mews should work out of the box with the tools terminal AI users already have:

- Copilot CLI through user-level hooks
- Claude Code and Codex through planned hook/notify integrations
- long-running shell commands

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
mw setup --yes --include-task-title # Opt in to short local task labels
mw start       # Start the local agent after setup
mw status      # Show the current local state
mw history     # Show recent local events
mw listen      # Listen in the terminal and print events as they arrive
mw doctor      # Check setup and fix anything that needs attention
mw undo        # Remove Mews-installed integrations and setup state
```

For people who want to script Mews directly:

```bash
mw notify      # Send a custom status event
mw run -- cmd  # Run a command and notify when it exits
mw stop        # Stop the local agent
mw reset --yes # Delete local Mews data and logs
```

## What Mews Is Not

Mews is not an AI chat app, not a Claude wrapper, not a Codex dashboard, not a Copilot replacement, and not a team monitoring product.

It is a small Mac companion for people who run AI agents in terminals and do not want to babysit them.

## Roadmap

### Current init preview

- Copilot CLI hook setup
- Local notifications and event history
- Setup doctor, undo, and reset
- Terminal listener before the Mac app exists
- Local agent and event pipeline
- Scriptable event notifications

### Planned next

- Claude Code and Codex integrations
- Menu bar status
- Safe uninstall and rollback for every integration
- Homebrew install

## Product Notes

Longer design notes live under [docs/](./docs/).
