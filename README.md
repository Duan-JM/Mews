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

Mews.app uses one attention channel for each semantic primary-session transition to completion, failure, or input needed. Duplicate hooks, log replay or rotation, and app restarts do not alert the same round again. Returning to running or idle resolves that attention, while a later completion, failure, or input-needed transition creates a new round. When a physical notch is available, the notch shell presents the transition without also sending a macOS notification. In clamshell mode, on displays without a notch, or while no display is available, Notification Center remains the fallback. Subagent completions and recoverable errors stay in local history without replacing the primary menu bar state or interrupting you. Fallback notifications identify the agent and status in the title, then show the project and a shortened session identifier when the tool provides them. The body describes the lifecycle action without exposing the full working directory, full session identifier, prompt, or terminal output. To show a short task label in the body, opt in explicitly:

```bash
mw setup --yes --include-task-title
```

That stores at most 80 local-only characters from a hook-provided prompt or title. Mews still does not upload prompts, transcripts, or terminal output.

The app bundle includes the Mews cat logo as its macOS icon. Native fallback notifications use that app identity instead of adding the logo as notification content. They expose **Return to CLI** and **Copy Return Command** actions when the event has usable local context. Returning through a notification, the panel, or a session menu item acknowledges only that session's current attention; copying the command does not. Returning copies a Mews-generated command such as `mw history --session 'abc123'`, then prefers the existing source terminal. Mews switches the recorded tmux client back to the source session, window, and pane when available. If that client has detached but the tmux server and pane still exist, Mews opens a new kitty window and attaches directly to the recorded pane. It can also focus a kitty window when kitty already exposes a local Unix remote-control socket. If an exact kitty or detached tmux context cannot be restored, Mews opens and activates a new kitty window at the validated event working directory even when kitty is already running. Other terminal profiles use the configured terminal at that directory when their source context is unavailable. Mews never changes kitty configuration, executes command text supplied by an event, or reads terminal scrollback.

Setup installs:

- Claude Code lifecycle hooks in `~/.claude/settings.json`.
- Codex's top-level `notify` command in `~/.codex/config.toml`.
- Copilot CLI user-level hooks in `~/.copilot/hooks/mews.json`.

Existing Claude and Codex files are backed up before editing. Mews preserves unrelated settings, refuses conflicting or malformed structures it cannot edit safely, and records every managed path in `integrations.json`. Restart the agent CLIs after setup so they reload their configuration.

If something cannot be enabled safely, Mews leaves it alone and explains the fix in `mw doctor`.

## Runtime health

`mw status`, `mw doctor`, and the native companion read the same local runtime-health snapshot. Health is `checking` when a transition is pending and no confirmed degraded or blocked capability outranks it, `ready` when every configured capability works, `degraded` when an optional capability such as notifications or one integration is affected, and `blocked` when core local event delivery cannot work. The menu and expanded shell stay quiet for `checking`, `ready`, and stale evidence. A fresh `degraded` or `blocked` capability appears with its bounded message and a copyable recovery instruction when one exists. The local agent checks health every two seconds and requires two consecutive matching observations before applying either degradation or recovery. Mews.app refreshes notification authorization every 30 seconds; status older than 90 seconds is stale.

## Why

AI agents are easy to start and easy to forget.

You ask Claude Code to refactor a file, leave Codex running tests, or let Copilot CLI work through a command. Then you switch apps. Ten minutes later the agent may be done, stuck, or waiting for permission, but the only signal is buried in a terminal pane.

Mews turns that hidden state into a small local signal.

## MVP

- A single physical-notch prompt or native macOS notification fallback for primary-agent attention events.
- A local JSONL history so missed notifications are not gone forever.
- A menu bar companion with a state-responsive pixel logo, an active-session list, and a compact notch/top-center shell.
- Clear doctor output for setup, all integrations, notification permission, LaunchAgent, socket, and the menu bar app.
- Bounded local event history and an isolated package smoke test.

## Mac Companion

The current menu bar companion is intentionally thin. It starts the local IPC agent, reads local event history and recoverable session state, and shows the latest state through a compact pixel logo. Left-clicking the logo opens the active-session shell aligned to a physical notch or the top center of another display; right-clicking or Control-clicking opens the active-session, history-only event, Refresh, and Quit menu.

The shell follows display changes without keeping stale geometry. It prefers an available physical notch, falls back to a detached material panel below the main display's menu bar in clamshell or external-display layouts, hides during a transient no-screen state, and repositions when a display returns. On a notched display, a narrow neck matches the hardware while a visible strip below it shows the pixel mascot and `IDLE`, `RUN`, `ASK`, `DONE`, or `FAIL`. Input-needed, completion, and failure events briefly widen that strip with a plain-language status, then return to the compact state; clicking the visible shell expands the existing panel from the same anchor. The same live topology selects the attention channel: a physical-notch event uses the shell, while other layouts use Notification Center without auto-opening the top-center panel. The panel joins all Spaces and full-screen auxiliary windows. Reduce Motion keeps the size changes static and uses a short fade, Reduce Transparency and Increase Contrast select an opaque high-contrast top-center surface, and VoiceOver receives explicit status and panel labels.

Presentation freshness is bounded without deleting history. `running` and `needs_input` remain current for up to 24 hours; `done` and `failed` remain current for 30 minutes. Expired session attention resolves and matching delivered notifications are removed where Notification Center permits it. Claude Code and Copilot CLI sessions with explicit lifecycle evidence remain in the active-session list between turns for up to 24 hours, and `SessionEnd` removes them immediately. Codex currently provides completion without a matching close event, so a stopped Codex session stays visible only for the 30-minute settled freshness window. Older evidence remains available through local history. A responsive agent that was started outside the app is reused rather than duplicated or terminated. If the bundled agent exits or is temporarily unavailable, restart attempts back off from 10 seconds to a five-minute cap instead of spinning on every two-second history refresh.

The expanded shell keeps its fixed 420×220 frame and shows every displayable active session in a native vertical scroll view. Sessions are ordered by `needs_input`, `failed`, `running`, unacknowledged stopped, then acknowledged stopped state. Each row shows the agent, bounded project label, shortened session reference, status, and its own **Return** and **Copy** controls. Row order and health controls stay fixed while identities remain available, while an explicitly closed session disappears immediately. Events without a stable session identity remain history-only instead of becoming fake sessions or occupying the active panel. Full session identifiers, working directories, subagent events, recoverable failures, prompt text, and runner command text are not rendered. Actions use only validated local context and Mews-generated history commands; unavailable actions stay disabled.

The monochrome pixel mascot now sleeps while idle, works while an agent runs, signals when input is needed, and plays a short one-shot pose for completion or failure.

### Synthetic interface previews

The compact synthetic preview shows the solid-black physical-notch treatment in light and dark appearance with the pixel mascot and the `IDLE`, `RUN`, `ASK`, `DONE`, and `FAIL` states.

![Synthetic Mews physical-notch states in light and dark appearance with the pixel mascot and IDLE, RUN, ASK, DONE, and FAIL labels](assets/screenshots/mews-status-states.png)

The light-appearance top-center material panel reports five active sessions and shows the first scroll position with `needs_input`, `failed`, stopped, and running rows. Its safe local contexts enable **Return** and **Copy**, while unavailable contexts leave both controls visibly disabled.

![Synthetic light-appearance top-center material panel reporting five active sessions, with visible needs-input, failed, stopped, and running rows plus enabled and disabled Return and Copy controls](assets/screenshots/mews-multi-session.png)

The dark-appearance top-center material panel shows an event-delivery warning with **Copy Fix**, an actionable running session, and a stopped session with disabled controls.

![Synthetic dark-appearance top-center material panel reporting two active sessions, with a degraded event-delivery row, Copy Fix control, actionable running session, and disabled stopped session](assets/screenshots/mews-degraded-health.png)

Contributors regenerate all three fixed-size images with `make screenshots`. The development-only fixtures render no local event history, prompts, terminal output, usernames, home paths, or real or long session identifiers.

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
