<div align="center">
  <h1>Mews</h1>
  <p><em>🐈 Never miss your AI agents again.</em></p>
</div>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-local--first-black?style=flat-square" alt="macOS local first">
  <img src="https://img.shields.io/badge/Homebrew-planned-orange?style=flat-square" alt="Homebrew planned">
  <img src="https://img.shields.io/badge/license-GPL_v3-blue.svg?style=flat-square" alt="License">
  <img src="https://img.shields.io/badge/status-product--draft-lightgrey?style=flat-square" alt="Product draft">
</p>

Mews sits quietly in your menu bar and watches the AI agents you run from terminal.

When Claude Code, Codex, Copilot CLI, or a long tmux task finishes, fails, or needs you, Mews lets you know. You do not have to keep checking every pane.

> This repository is currently a product draft. The README describes the product we want the first public version to feel like.

## Install

```bash
brew install mews
mews start
```

That is the whole setup.

Mews starts a small menu bar companion, finds the AI CLI tools already on your Mac, enables local notifications where it can, and tells you what it is watching.

```text
Mews is watching:
  ✓ Claude Code
  ✓ Codex
  ✓ Copilot CLI
  ✓ tmux
```

If something cannot be enabled safely, Mews leaves it alone and explains the fix in `mews doctor`.

## Why

AI agents are easy to start and easy to forget.

You ask Claude Code to refactor a file, leave Codex running tests in tmux, or let Copilot CLI work through a command. Then you switch apps. Ten minutes later the agent may be done, stuck, or waiting for permission, but the only signal is buried in a terminal pane.

Mews turns that hidden state into a small local signal.

## What You See

- A menu bar icon that shows whether an agent is running, done, failed, or waiting.
- A short notification when an agent needs your attention.
- A recent history list, so missed notifications are not gone forever.
- A quiet idle state when nothing is happening.

Later, **Mews for Mac** can add the notch cat: a small cat around the MacBook notch that walks while agents run, naps when idle, pounces when something finishes, and gets your attention when a prompt is waiting.

## What Mews Watches

Mews should work out of the box with the tools terminal AI users already have:

- Claude Code
- Codex
- Copilot CLI
- tmux
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

Most users should only need two commands:

```bash
mews start       # Start Mews and enable supported tools
mews doctor      # Check setup and fix anything that needs attention
```

For people who want to script Mews directly:

```bash
mews notify      # Send a custom status event
mews run -- cmd  # Run a command and notify when it exits
mews stop        # Stop the menu bar companion
```

## What Mews Is Not

Mews is not an AI chat app, not a Claude wrapper, not a Codex dashboard, not a Copilot replacement, and not a team monitoring product.

It is a small Mac companion for people who run AI agents in terminals and do not want to babysit them.

## Roadmap

### Open-source Mews

- Two-step install
- Menu bar status
- Automatic setup for supported tools
- Local notifications
- Recent event history
- Setup doctor
- Safe uninstall and rollback
- Homebrew install

### Mews for Mac

- Notch cat
- Multi-agent panel
- Visual setup and repair
- Themes and sounds
- Better history and project grouping
- External display behavior

## Product Notes

The pre-App Store product design lives in [pre-app-store-product-design.md](./pre-app-store-product-design.md).
