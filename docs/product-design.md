# Mews Product Design

## One-line Positioning

Mews is a local macOS companion for people who run AI coding agents in terminals. It watches explicit agent lifecycle events and lets you know when a task finishes, fails, or needs attention.

> Mews keeps an eye on your terminal AI agents, so you do not have to.

## Current Product Direction

Mews should stay small, local, and terminal-friendly. The first useful version should make one promise: if an AI agent stops needing the terminal in front of you, Mews makes that state visible.

The product should not become an AI dashboard or a second chat surface. It should be a quiet menu bar utility with a clear CLI, safe setup, and reliable undo.

## Target Users

### Core Users

Developers who run AI coding agents in macOS terminals:

- Claude Code users
- Codex CLI users
- Copilot CLI users
- People who keep multiple terminal panes open while agents edit code, run tests, or wait for permission

### Secondary Users

macOS power users who like local utilities and want a low-noise, scriptable status notifier instead of a full dashboard.

## User Problems

1. AI agents often finish while the user is looking somewhere else.
2. Failed, blocked, or permission-waiting states are easy to miss outside the terminal.
3. Multiple agents can run at once, making it hard to know which project needs attention.
4. System notifications disappear quickly, so there needs to be a small local history.
5. Generic menu bar or notch tools are not designed around AI agent lifecycle events.

## What Mews Does

The first stage turns explicit terminal-agent events into local, low-noise status.

Scope:

- Receive local events from CLI commands, hooks, wrappers, or scripts.
- Show the latest state in the macOS menu bar.
- Keep a short recent-event history.
- Support system notifications.
- Provide integrations for Claude Code, Codex, and Copilot CLI when stable hooks are available.
- Provide `mw run -- <command>` as a wrapper fallback for tools without lifecycle hooks.
- Avoid transcript, code, prompt, and terminal scrollback capture by default.

## What Mews Does Not Do

- It is not an AI chat client.
- It does not replace Claude Code, Codex, or Copilot CLI.
- It does not read full code, full conversations, or terminal scrollback by default.
- It does not sync to cloud services.
- It is not a team monitoring product.
- It is not a general log analysis platform.
- It does not promise automatic detection of every terminal state in the first version.

## MVP Scope

The MVP only needs to prove that users stop missing important AI agent states.

Must have:

1. `mw setup --yes`
2. `mw notify --source copilot --status done --project Mews --message "Task finished"`
3. Claude Code, Codex, and Copilot CLI lifecycle integration.
4. Local event history.
5. `mw doctor` that reports setup, hook, store, and companion state honestly.
6. `mw undo` for Mews-owned integrations.
7. Clear privacy copy in the README.
8. A thin menu bar companion launched by `mw start`.
9. Versioned, checksummed packages and a credential-gated signed release path.

Can wait:

1. Graphical setup.
2. Long-term event history.
3. Automatic terminal-state detection.
4. Quiet mode and richer notification rules.

## State Model

Mews first handles five states:

| State | Meaning | UI expression |
|---|---|---|
| `running` | Agent is working | Running state in the menu bar |
| `needs_input` | Main agent is waiting for user input, permission, or confirmation | Stronger attention signal |
| `done` | Main task finished | Gentle notification |
| `failed` | Main task failed or a command exited unexpectedly | Clear failure state |
| `idle` | No active task | Quiet idle state |

Events stay deliberately small:

```json
{
  "source": "copilot",
  "session_id": "abc123",
  "project": "Mews",
  "status": "done",
  "message": "Task finished",
  "timestamp": "2026-07-07T18:40:00+08:00"
}
```

## Interaction Principles

1. Quiet by default. Only primary-agent completion, non-recoverable failure, and user-needed states should interrupt.
2. The menu bar should be reliable. Extra visuals are optional enhancements.
3. Integrations must be explicit. Mews should not secretly read terminal output.
4. Missed notifications and silent subagent events should be recoverable from recent local history.
5. Stale states should return to `idle` instead of getting stuck forever.
6. Returning to work should take one action: switch an available tmux client back to the original pane, or open kitty and attach when the validated same-user tmux socket and pane still exist without a client. If neither path is available, use the configured terminal and a validated directory. Keep a local Mews history command on the clipboard without executing event-provided command text.

## Install and Distribution

The release package path is:

```bash
tar -xzf mews-vX.Y.Z-darwin.tar.gz
cd mews-vX.Y.Z-darwin
sudo ./install.sh
mw setup --yes
mw start
mw doctor
mw notify --status done --message "Hello"
```

Local development uses:

```bash
make build
./bin/mw setup --yes
./bin/mw start
./bin/mw doctor
```

## README Opening Copy

```text
Mews

Never miss your AI agents again.

A tiny local macOS companion for Claude Code, Codex, Copilot CLI, and terminal-first AI workflows.
```

## Success Signals

1. Users keep Mews running during real AI coding sessions.
2. Users can tell which project or session needs attention without reopening every terminal.
3. Copilot lifecycle notifications work without scraping terminal content.
4. Setup and undo feel safe enough for users to try without fear.
5. Users ask for more integrations after the first one proves useful.

## Product Risks

### Risk 1: Agent hooks are inconsistent across tools

Use official lifecycle hooks where available. Keep `mw run -- <command>` as a fallback for tools without hooks.

### Risk 2: Visual polish distracts from the core loop

Keep the first version focused on event capture, local history, notifications, and honest diagnostics.

### Risk 3: Users worry about privacy

Accept explicit events only. Do not read transcripts, code, prompts, or terminal scrollback by default. Make task-title capture opt-in and local-only.

### Risk 4: State detection becomes unreliable

Avoid guessing from terminal output. Prefer hooks, wrappers, and explicit user events.

## Recommended Direction

Keep Mews focused on one job: turning AI agent lifecycle events into reliable local Mac status.

The product boundary matters more than feature count. Mews should stay quiet, reversible, and trustworthy.
