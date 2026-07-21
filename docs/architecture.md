# Mews Architecture

## Product Goal

Mews is a local macOS companion for terminal AI agents. The first public version should feel like this:

```bash
brew install mews
mw setup
mw setup --yes
mw start
```

After that, Mews starts a menu bar companion, installs the supported Claude Code, Codex, and Copilot CLI integrations, and keeps a recent status history. Users should not need to edit those configuration files by hand.

## Non-Goals

- No cloud service.
- No account system.
- No team dashboard.
- No AI chat UI.
- No transcript sync.
- No terminal scrollback scraping by default.
- No notch cat as a required MVP dependency.

## Design Principles

1. **Install, setup, start, undo**: the main path is `brew install mews`, `mw setup`, `mw start`, and `mw undo`.
2. **Menu bar first**: status must be visible even if notifications are missed.
3. **Local-only**: all state stays under the current macOS user account.
4. **No surprise writes**: Mews explains what it will enable, writes backups, and can undo its own changes.
5. **Fail honestly**: unsupported tools show as unsupported, not silently broken.
6. **Advanced paths stay advanced**: `mw notify`, wrappers, and hook details exist, but do not lead the product.

## System Overview

```text
                  ┌────────────────────┐
                  │      mw CLI       │
                  │ start/status/doctor │
                  └─────────┬──────────┘
                            │ local IPC
                            ▼
┌──────────────┐    ┌────────────────────┐    ┌───────────────────┐
│ Integrations │───▶│ Mews Menu Bar Agent │───▶│ macOS Notification │
│ hooks/wraps  │    │ state + UI + rules  │    │ Center             │
└──────────────┘    └─────────┬──────────┘    └───────────────────┘
                              │
                              ▼
                    ┌────────────────────┐
                    │ Local Store         │
                    │ events + settings   │
                    └────────────────────┘
```

Mews has two runtime pieces:

1. **`mw` CLI**: user-facing command installed from a verified release package or a future Homebrew tap.
2. **Mews Menu Bar Agent**: a native Swift/AppKit LSUIElement app launched by `mw start`.

The CLI handles setup, diagnostics, undo, and scriptable events. The agent owns the menu bar icon, notification delivery, current state, recent history, and local IPC server.

## Runtime Components

### 1. `mw` CLI

Responsibilities:

- Start and stop the menu bar agent.
- Resolve supported integration paths.
- Install and remove integrations.
- Send custom events with `mw notify`.
- Wrap commands with `mw run -- <command>`.
- Run diagnostics with `mw doctor`.
- Revert changes with `mw undo`.

Recommended commands:

```bash
mw setup      # Show the supported integration plan
mw start      # Start the local agent after setup
mw status     # Print current watched tools and agent state
mw config terminal <name> # Select the terminal used for return actions
mw history    # Show recent local events
mw history --session <id> # Show recent events for one session reference
mw listen     # Listen in the terminal and print events as they arrive
mw doctor     # Diagnose permissions, hooks, LaunchAgent, and IPC
mw stop       # Stop the local agent
mw undo       # Remove Mews-installed integrations and restore backups
mw reset --yes # Delete local Mews data and logs after undo

mw notify     # Advanced: send a custom event
mw run -- cmd # Advanced: run a command and report completion
```

### 2. Mews Menu Bar Agent

Responsibilities:

- Render current state as a compact, monochrome pixel logo in the menu bar.
- Open a compact status shell at the physical notch or top center from that pixel logo.
- Show recent event history.
- Deliver macOS notifications.
- Receive local events from integrations and the CLI.
- Deliver native notifications for the implemented attention states.
- Return to a validated source terminal context when possible, or open the configured terminal working directory.
- Copy a Mews-owned session history command from notification actions.
- Persist recent events and settings.

The agent is packaged as a small app bundle so macOS menu bar identity, notification permission, and local visibility are reliable. It starts the bundled `mw agent` helper, renders a state-responsive template pixel logo, reads local event history for the context menu, opens a compact notch/top-center shell, and delivers native notifications for attention states.

The shell keeps a pure `closed` / `peek` / `expanded` interaction policy separate from AppKit timers and event monitors. AppKit owns the fixed 420×220 nonactivating panel, display placement, passive local/global mouse observation, and teardown. Outside clicks close an expanded panel without consuming or synthesizing the target event. SwiftUI renders the black morphing shell inside that frame. Left-clicking the status item toggles the shell, while right-click and Control-click preserve the existing event, Refresh, and Quit menu. Physical-notch hover is optional: if global hover monitoring is unavailable, the app logs the degradation and keeps the status-item click and top-center fallback paths.

Presentation changes can show a noninteractive peek without collapsing an expanded shell. `needs_input` persists until the state changes or the user expands or closes it, `done` peeks for 2.5 seconds, and `failed` peeks for 4 seconds. Completion and failure peeks are deduplicated by the presentation transition identifier. `running` and `idle` do not auto-open. The current shell contains only the pixel status and a minimal header; detailed status cards and panel-level terminal-return controls remain future work.

### 3. Integration Manager

Responsibilities:

- Resolve the supported configuration path for each tool.
- Validate existing configuration before choosing a safe edit.
- Install integration files with backups.
- Verify that integrations can call back into Mews.
- Report integration status to `mw doctor`.

Supported tools in the first version:

| Tool | First strategy | Fallback |
|---|---|---|
| Claude Code | Install local hook commands after confirmation | Use `mw run -- <command>` for process-exit fallback |
| Codex | Install a top-level notify command after confirmation | Use `mw run -- <command>` for process-exit fallback |
| Copilot CLI | Install user-level hooks in `~/.copilot/hooks/mews.json` | `mw run -- copilot` for process-exit fallback |
| Custom scripts | `mw notify` | None |

### 4. Local Store

The store is local and user-scoped.

Recommended paths:

```text
~/Library/Application Support/Mews/
  config.json
  events.jsonl
  integrations.json
  backups/
  copilot-hooks/
  mews.sock

~/Library/Logs/Mews/
  app.log
  agent.log

~/Library/LaunchAgents/
  dev.mews.agent.plist
```

Storage format:

- `config.json`: setup state, terminal preference, and notification rules.
- `events.jsonl`: append-only recent event log, capped by size or age.
- `integrations.json`: installed integration records and backup paths.
- `backups/`: original config files before Mews modifies them.
- `copilot-hooks/`: opaque hashes used to correlate Copilot subagent lifecycle events.

The socket normally lives in Application Support. If the full path would exceed the macOS Unix socket limit, Mews uses a private `0700` directory under the system temporary directory for the current user.

SQLite can wait. JSON and JSONL are easier to inspect, back up, and repair in the first version.

## Data Flow

### `mw setup`

```text
User runs mw setup
  │
  ├─ Resolve the store, log, app, and integration paths
  ├─ Show the Claude Code, Codex, and Copilot CLI writes
  ├─ Show the terminal return profile and task-title policy
  └─ With --yes:
      ├─ Install supported integrations with backups
      ├─ Record installed files and backups in integrations.json
      └─ Print the mw start next action
```

Representative plan output, with paths shortened:

```text
Mews setup plan

Mews will:
  - create store: <home>/Library/Application Support/Mews
  - create logs: <home>/Library/Logs/Mews
  - launch menu bar app: <path-to-Mews.app>
  - install Copilot CLI hooks: <copilot-home>/hooks/mews.json
  - install Claude Code hooks: <home>/.claude/settings.json
  - install Codex notify integration: <home>/.codex/config.toml
  - include project, cwd, hook event, and session metadata in events
  - return to terminal: auto (origin terminal, Terminal fallback)
  - skip task titles by default; use --include-task-title to opt in
  - record setup state for `mw doctor` and `mw undo`

Run `mw setup --yes` to apply this safe local setup.
Run `mw undo` later to remove Mews-owned setup state.
```

### `mw start`

```text
User runs mw start
  │
  ├─ Verify setup state exists
  ├─ Install or refresh the LaunchAgent for Mews.app
  ├─ Launch menu bar app
  ├─ Wait for the bundled local agent socket
  └─ Print the LaunchAgent and store paths
```

Representative output:

```text
Mews menu bar app is running.
  LaunchAgent: <home>/Library/LaunchAgents/dev.mews.agent.plist
  Store: <home>/Library/Application Support/Mews
```

### Agent Event Delivery

```text
AI tool event
  │
  ├─ hook, wrapper, or mw notify
  │
  ▼
mw CLI validates event
  │
  ▼
Unix domain socket
  │
  ▼
Menu bar agent
  │
  ├─ update current status
  ├─ append to events.jsonl
  └─ let Mews.app show a native notification for attention states
```

### `mw undo`

```text
User runs mw undo
  │
  ├─ Read integrations.json
  ├─ Remove exact Mews-managed hook commands and marker blocks
  ├─ Preserve unrelated edits made after setup
  ├─ Remove generated Mews-owned files
  ├─ Unload and remove the Mews LaunchAgent
  ├─ Stop the menu bar agent
  ├─ Remove setup state while keeping event history
  └─ Print restored items
```

Rollback is part of the product, not a debug feature.

### `mw reset`

```text
User runs mw reset --yes
  │
  ├─ Refuse to run without --yes
  ├─ Refuse while integration rollback state still exists
  ├─ Delete Mews local store
  ├─ Delete Mews logs
  └─ Print deleted paths
```

Reset deletes local Mews data and event history. It should not be used as a substitute for `mw undo`, because it does not restore third-party config files.

## Event Model

Mews should keep the event model small.

```json
{
  "version": 1,
  "source": "copilot",
  "hook_event": "agentStop",
  "agent_scope": "main",
  "session_id": "abc123",
  "project": "Mews",
  "task_title": "Fix doctor output",
  "status": "done",
  "recoverable": false,
  "message": "Agent stopped",
  "cwd": "/Users/name/project",
  "pid": 12345,
  "timestamp": "2026-07-07T18:40:00+08:00"
}
```

Required fields:

- `version`
- `source`
- `status`
- `timestamp`

Optional fields:

- `session_id`
- `hook_event`
- `agent_scope`
- `recoverable`
- `project`
- `task_title`
- `message`
- `cwd`
- `pid`
- `terminal`
- `terminal_window_id`
- `kitty_listen_on`
- `tmux_socket`
- `tmux_pane`
- `tmux_client`

Supported statuses:

| Status | Meaning | Notification behavior |
|---|---|---|
| `running` | Work started or resumed | Usually silent |
| `needs_input` | User action is needed | Notify for the primary agent |
| `done` | Work completed | Notify for the primary agent |
| `failed` | Work failed | Notify when the failure is not recoverable |
| `idle` | No active work | Silent |

`agent_scope` is `main` or `subagent` when an integration can identify it. Subagent events and recoverable errors remain in local history, but do not replace the primary menu bar state or trigger a native notification.

The message should be short and safe. Integrations should avoid sending prompts, code snippets, or transcript content by default. Task titles are opt-in with `mw setup --yes --include-task-title`, must stay local-only, and must be truncated before storage.

When `session_id` is present, the CLI displays the local return command as `mw history --session '<id>'`. Notification and menu actions build the equivalent command with a shell-quoted absolute path to `Mews.app/Contents/Resources/mw`, so custom install prefixes still work when `$PREFIX/bin` is not on `PATH`.

The terminal preference defaults to `auto`. Auto uses the recorded source terminal when available and falls back to Terminal.app. An explicit profile uses that terminal unless the event came from the same profile, in which case Mews prefers the existing application. Supported profiles are Terminal, kitty, iTerm2, WezTerm, Ghostty, and Alacritty.

Return actions copy the Mews-owned history command and activate the source terminal. When an event originates in tmux, the CLI preserves the validated same-user socket and source pane even when no client is attached. If a client is available, the app uses one fixed `switch-client -c <client> -t <pane>` operation so tmux restores the source session, window, and pane together. If the client is absent or disappears before the action, the app verifies the pane with a fixed `display-message` operation. For kitty, it then opens a new active instance that runs a fixed `attach-session -t <pane>` command with inherited tmux variables removed. Kitty window focus is attempted only when the event carries a numeric kitty window ID and an existing local Unix remote-control address; Mews does not enable kitty remote control. A failed exact kitty or detached tmux restore skips generic application activation and opens a new active kitty instance with `--directory <cwd>`, even if kitty is already running. Other unavailable source contexts use the configured terminal at the event's validated absolute `cwd`. A directory-only event does not invent a session command. Mews never executes event-provided command text or reads terminal scrollback.

## IPC

Use a Unix domain socket under the user Application Support directory when the path fits:

```text
~/Library/Application Support/Mews/mews.sock
```

Reasons:

- Local to the user.
- No port collisions.
- No localhost firewall prompt.
- Easy for CLI and hook scripts to reach.

Long home paths use a private short path under the system temporary directory. If the socket is missing, `mw notify` appends the validated event locally. Notifications are delivered only by Mews.app through `UNUserNotificationCenter`; the CLI does not provide a separate notification fallback.

## Integration Strategy

### Claude Code

Mews installs user-level Claude Code hooks for `PermissionRequest`, `Stop`, `StopFailure`, and `SessionEnd`. Each command calls `mw notify` and receives hook JSON through stdin.

Rules:

- Back up existing settings before editing.
- Preserve user hooks.
- Record the exact Mews commands in `integrations.json`.
- Remove only those exact commands in `mw undo`.

### Codex

Mews installs Codex's top-level `notify` argv array and routes its JSON argument through `mw hook codex`. The managed TOML block has stable markers, is inserted before table declarations, and refuses to replace an existing top-level `notify` command.

### Copilot CLI

Use Copilot CLI user-level hooks when available. Mews should install a Mews-owned hook file at `~/.copilot/hooks/mews.json`, or `$COPILOT_HOME/hooks/mews.json` when `COPILOT_HOME` is set.

Mews can offer:

```text
Copilot CLI found.
User-level hooks installed.
Main-agent completion and failure events will notify Mews.
Subagent completion events will remain silent.
```

The managed hook file routes `sessionStart`, `subagentStart`, `subagentStop`, `agentStop`, `sessionEnd`, and `errorOccurred` through `mw hook copilot <event>`. `agentStop` maps to a main-agent `done` event, `subagentStop` maps to a silent subagent `done` event, `sessionEnd` maps to `idle`, and `errorOccurred` maps to `failed` while preserving Copilot's `recoverable` flag.

Some Copilot CLI versions can invoke `agentStop` while a subagent is finishing. Mews correlates the official subagent lifecycle using hashes of the session identifier and transcript path, suppresses that duplicate event, and clears the Mews-owned correlation state on session start, session end, and `mw undo`. Raw transcript paths and transcript contents are never stored. A hook-provided agent name is also enough to classify the event as a subagent.

Mews may derive `project` from `cwd` and preserve a hook `session_id` when provided. Do not read prompts, transcripts, or terminal scrollback by default; task titles require explicit opt-in and are truncated to 80 characters.

## Notification Rules

Implemented default behavior:

- Primary-agent `needs_input`: notify immediately.
- Primary-agent non-recoverable `failed`: notify immediately.
- Primary-agent `done`: notify immediately.
- Subagent events and recoverable errors: keep in history without notifying or replacing primary status.
- `running`: update menu bar only.
- `idle`: update menu bar only.

Notifications are delivered by the app bundle, which declares the Mews icon so Notification Center can show Mews identity. The logo is app identity only, not a notification attachment.

Action behavior:

- **Return to CLI**: copy the local session history command, then restore a validated source terminal, attach a new kitty window to a detached tmux target, or open the configured terminal at the event directory.
- **Copy Return Command**: copy only the Mews-generated session history command.
- Default notification clicks use the same open action.
- Relative, missing, and non-directory paths are never opened.

General duplicate suppression, runtime thresholds, and configurable quiet mode remain post-MVP notification policy work.

## Security and Privacy

Mews should make privacy boring and auditable.

Hard boundaries:

- No network requests for core functionality.
- No telemetry in MVP.
- No prompt, transcript, or code capture by default.
- Prompt-derived task titles require explicit opt-in, are truncated, and stay local.
- No terminal scrollback scraping by default.
- No shell command execution from received events.
- Terminal restoration only invokes fixed kitty and tmux `display-message`, `switch-client`, and `attach-session` operations with validated identifiers and same-user local sockets.
- No broad write access beyond known integration files and Mews-owned paths.

Config writes:

- Show what will be changed.
- Write backups before edits.
- Use stable markers around Mews-owned blocks.
- Support `mw undo`.
- Refuse to edit malformed config files and explain through `mw doctor`.

## Doctor

`mw doctor` is a first-class user experience.

It checks:

- Store and log directories writable.
- Event history writable.
- Setup state configured.
- Menu bar app bundle available.
- LaunchAgent loaded.
- Local agent running.
- Unix socket available.
- Notification permission granted.
- Integration rollback state ready.
- Claude Code hooks installed.
- Codex notify integration installed.
- Copilot CLI hook status.

Example:

```text
Mews Doctor

Store              writable
Logs               writable
Events             ready
Setup              configured
Menu bar app       <path-to-Mews.app>
LaunchAgent        loaded
Local agent        running
Socket             available
Notifications      authorized
Undo               ready
Claude Code        hooks installed
Codex              notify integration installed
Copilot CLI        hooks installed
```

## Packaging

The release package and future Homebrew formula install:

```text
bin/mw
libexec/Mews.app
```

The fallback installer writes only beneath `PREFIX` and does not edit shell startup files. Users of a custom prefix must expose `PREFIX/bin` through their shell configuration.

`mw setup`:

1. Resolve store, app, terminal, and supported integration paths.
2. Show every planned write and the task-title policy.
3. With `--yes`, write backups before editing tool config.
4. Record setup and rollback state.

`mw start`:

1. Verify setup exists.
2. Install `~/Library/LaunchAgents/dev.mews.agent.plist`.
3. Launch the app.
4. Verify IPC.

This keeps the install path simple while still using a proper app bundle for menu bar identity and macOS notifications.

`make build` produces universal `arm64` and `x86_64` CLI and app executables, then applies a complete ad-hoc signature to the local app bundle so menu bar identity and notification permission work during development. `make package` produces a versioned tarball and SHA-256 checksum. `VERSION=vX.Y.Z make release-check` runs tests, lint, checksum verification, and an isolated installed-runtime smoke that applies setup, executes all three generated integration paths through IPC, checks privacy-safe history, and verifies undo/reset. Formal `make release` must run from a clean `main` synchronized with `origin/main` and requires a Developer ID identity and notarization keychain profile. It replaces the local signature with Developer ID signatures, submits the app for notarization, staples the ticket, verifies with Gatekeeper, creates the release archive, and generates a checksum-pinned Homebrew formula for tap publication. Homebrew-managed hooks and LaunchAgent paths use the stable `opt/mews` prefix rather than a versioned Cellar path.

## Technology Choice

Mews should use Go as the primary implementation language.

Go owns:

- CLI commands.
- Setup, doctor, undo, and rollback.
- Integration path validation and management.
- Local store and event validation.
- Unix socket IPC.
- `mw notify` and `mw run`.
- Release binaries and Homebrew packaging.

`Mews.app` stays thin. The current app is a small Swift/AppKit LSUIElement app that owns the menu bar icon, AppKit panel behavior, and SwiftUI status shell while reusing the Go helper for local IPC. If a pure-Go menu bar implementation proves reliable enough, it can be considered, but the architecture should not force the product into a non-native Mac UX just to keep one language.

Do not use Rust in the first version. Mews needs simple distribution, fast iteration, and boring local tooling more than Rust's extra safety guarantees.

## Minimal Implementation Shape

Recommended structure:

```text
cmd/
  mw/
    main.go
internal/
  app/
  cli/
  doctor/
  events/
  integrations/
  ipc/
  launchd/
  store/
  terminal/
  undo/
lib/
  Mews.app/
scripts/
  build.sh
  package.sh
  release.sh
tests/
```

Use `cmd/` and `internal/` like Mole. Keep the public surface small, keep most implementation private, and make the root easy to understand.

Shared logic should live under `internal/` so CLI commands, integration installers, doctor checks, and tests use the same event validation and store behavior.

## Mole-Style Repository Management

Mews should copy Mole's repo discipline more than its exact feature set.

Recommended root:

```text
.github/
  workflows/
AGENTS.md
cmd/
docs/
internal/
lib/
scripts/
tests/
go.mod
Makefile
install.sh
README.md
SECURITY.md
SECURITY_AUDIT.md
CONTRIBUTING.md
```

Repository rules:

1. **Root stays product-facing**: README, install script, security docs, contributing guide, and Makefile should be enough for a new contributor to understand the project.
2. **Go code follows `cmd/` + `internal/`**: no sprawling packages at root.
3. **Scripts are explicit**: build, package, release, and local install scripts live under `scripts/`; `install.sh` stays as the user-facing fallback installer.
4. **Makefile is the contributor API**: common tasks should be discoverable through `make lint-tools`, `make hooks`, `make check`, `make test`, `make build`, `make lint`, `make package`, and `make install-local`.
5. **Security docs are first-class**: because Mews edits local tool configs, it needs `SECURITY.md` and a practical `SECURITY_AUDIT.md` from the start.
6. **Workflows stay boring**: CI runs tests, lint, shellcheck, CodeQL, package checksum verification, and an isolated artifact smoke. Signing remains an explicit credential-gated maintainer action.

Makefile targets:

```text
make lint-tools     # Install pinned Go, Swift, and Shell lint binaries under .tools/bin
make hooks          # Install pre-commit lint and pre-push test hooks
make check          # Run lint, tests, and the build
make build          # Build mw CLI and package Mews.app
make test           # Run Go tests and Swift model tests
make lint           # Run Go, Swift, source-size, and shell lint checks
make package        # Produce local release artifact
make release        # Sign, notarize, verify, and package a release
make install-local  # Install into a local test prefix
make clean          # Remove build outputs
```

Workflows:

```text
check.yml           # Go, Swift, source-size, and shell lint checks
test.yml            # Go tests and Swift model tests
codeql.yml          # CodeQL scan
package.yml         # build, checksum, and artifact smoke
```

The goal is the same feeling as Mole: a serious local Mac utility with simple commands, visible safety boundaries, and a repository that does not feel over-engineered.

## Verification Plan

Manual acceptance checks:

1. Fresh install, run `mw setup` to review planned integration writes.
2. Run `mw setup --yes`, then `mw start`; the menu bar icon appears.
3. `mw doctor` reports green state after setup.
4. `mw notify --status done --message "Task finished"` updates menu bar and history.
5. `mw run -- false` produces a failed event.
6. Claude Code notification hook reaches Mews without exposing transcript content.
7. A notification action copies the Mews session command, returns to an attached source terminal, opens kitty on a detached tmux target, or falls back to the recorded directory.
8. `mw undo` restores backed-up config and removes Mews-owned files.
9. With notifications denied, menu bar status still works and doctor explains the permission.
10. With the agent stopped, `mw notify` stores the validated event locally for later history.
11. With malformed third-party config, Mews refuses to edit and leaves the file unchanged.
12. A Copilot subagent completion stays in history without triggering a native notification or replacing primary status.
13. The pixel logo opens the compact notch/top-center shell, while right-click and Control-click retain the existing menu.

Automated tests:

- Event validation.
- Primary-agent and subagent notification policy.
- Notification action routing, terminal metadata validation, and CLI-context path validation.
- Closed, peek, and expanded shell policy, notification-peek timing, deduplication, and placement hit testing.
- JSONL store append and rotation.
- IPC request parsing.
- Integration marker insertion and removal.
- Backup and restore behavior.
- Doctor checks for missing socket, denied notification permission, and unwritable store.

## Rollback

Every external write must have a rollback path:

| Write | Rollback |
|---|---|
| LaunchAgent plist | unload and delete plist |
| Claude Code settings | restore backup or remove Mews marker block |
| Codex config | restore backup or remove Mews marker block |
| Copilot CLI hook | remove the Mews-owned hook file |
| Copilot hook correlation state | delete the Mews-owned opaque marker directory |
| Mews store | keep by default, delete with explicit reset command |

`mw undo` should not delete event history unless the user runs a separate reset command.

## Open Questions

1. Copilot CLI lifecycle compatibility needs real-session verification across supported versions, especially agents that omit explicit subagent lifecycle events.
2. Claude Code and Codex integrations need real-session compatibility checks as upstream payloads evolve.
3. The Homebrew tap layout must preserve the signed app bundle and checksum verification.

These do not block the first architecture because each has a safe fallback.
