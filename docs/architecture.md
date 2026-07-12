# Mews Architecture

## Product Goal

Mews is a local macOS companion for terminal AI agents. The first public version should feel like this:

```bash
brew install mews
mw setup
mw setup --yes
mw start
```

After that, Mews starts a menu bar companion, finds supported AI tools, enables local notifications where it can, and keeps a recent status history. Users should not need to edit Claude Code, Codex, or Copilot CLI configuration by hand.

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
- Detect installed tools.
- Install and remove integrations.
- Send custom events with `mw notify`.
- Wrap commands with `mw run -- <command>`.
- Run diagnostics with `mw doctor`.
- Revert changes with `mw undo`.

Recommended commands:

```bash
mw setup      # Show and apply supported local integrations
mw start      # Start the local agent after setup
mw status     # Print current watched tools and agent state
mw history    # Show recent local events
mw listen     # Listen in the terminal and print events as they arrive
mw doctor     # Diagnose permissions, hooks, LaunchAgent, and IPC
mw stop       # Stop the local agent
mw undo       # Remove Mews-installed integrations and restore backups
mw reset      # Delete local Mews data and logs

mw notify     # Advanced: send a custom event
mw run -- cmd # Advanced: run a command and report completion
```

### 2. Mews Menu Bar Agent

Responsibilities:

- Render current state in the menu bar.
- Show recent event history.
- Deliver macOS notifications.
- Receive local events from integrations and the CLI.
- Deliver native notifications for the implemented attention states.
- Persist recent events and settings.

The agent is packaged as a small app bundle so macOS menu bar identity, notification permission, and local visibility are reliable. It starts the bundled `mw agent` helper, reads local event history for the menu, and delivers native notifications for attention states.

### 3. Integration Manager

Responsibilities:

- Discover installed tools.
- Decide the safest available integration for each tool.
- Install integration files with backups.
- Verify that integrations can call back into Mews.
- Report unsupported or partially supported tools to `mw doctor`.

Supported tools in the first version:

| Tool | First strategy | Fallback |
|---|---|---|
| Claude Code | Install local hook command after confirmation | Show manual instructions in `mw doctor` |
| Codex | Use notify command or config-backed hook after confirmation | Suggest `mw run -- codex` |
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
  mews.sock

~/Library/Logs/Mews/
  app.log
  agent.log

~/Library/LaunchAgents/
  dev.mews.agent.plist
```

Storage format:

- `config.json`: user preferences and notification rules.
- `events.jsonl`: append-only recent event log, capped by size or age.
- `integrations.json`: installed integration records and backup paths.
- `backups/`: original config files before Mews modifies them.

The socket normally lives in Application Support. If the full path would exceed the macOS Unix socket limit, Mews uses a private `0700` directory under the system temporary directory for the current user.

SQLite can wait. JSON and JSONL are easier to inspect, back up, and repair in the first version.

## Data Flow

### `mw setup`

```text
User runs mw setup
  │
  ├─ Ensure Application Support and Logs directories exist
  ├─ Show the Claude Code, Codex, and Copilot CLI writes
  ├─ Ask for approval before writing tool configs
  ├─ Install supported integrations with backups
  ├─ Record installed files and backups in integrations.json
  └─ Print undo and start next actions
```

Expected output:

```text
Mews setup plan:
  ✓ Claude Code
  ✓ Codex
  ✓ Copilot CLI

Run `mw setup --yes` to apply.
Run `mw undo` later to remove these changes.
```

### `mw start`

```text
User runs mw start
  │
  ├─ Verify setup state exists
  ├─ Install or refresh the LaunchAgent for Mews.app
  ├─ Launch menu bar app
  ├─ Wait for the bundled local agent socket
  └─ Print watched tools and next action
```

Expected output:

```text
Mews is watching configured tools.
Menu bar companion started.
Run `mw doctor` if something does not notify correctly.
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
  ├─ Unload LaunchAgent if requested
  ├─ Stop menu bar agent if requested
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
  "source": "claude-code",
  "hook_event": "agentStop",
  "session_id": "abc123",
  "project": "Mews",
  "task_title": "Fix doctor output",
  "status": "done",
  "message": "copilot done: Mews - Fix doctor output",
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
- `project`
- `task_title`
- `message`
- `cwd`
- `pid`

Supported statuses:

| Status | Meaning | Notification behavior |
|---|---|---|
| `running` | Work started or resumed | Usually silent |
| `needs_input` | User action is needed | Notify immediately |
| `done` | Work completed | Notify if task lasted long enough |
| `failed` | Work failed | Notify immediately |
| `idle` | No active work | Silent |

The message should be short and safe. Integrations should avoid sending prompts, code snippets, or transcript content by default. Task titles are opt-in with `mw setup --yes --include-task-title`, must stay local-only, and must be truncated before storage.

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

Long home paths use a private short path under the system temporary directory. If the socket is missing, `mw notify` appends the validated event locally and uses an `osascript` notification fallback.

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
Agent stop and session end events will call `mw notify`.
```

`agentStop` should map to `done`, `sessionEnd` to `idle`, and `errorOccurred` to `failed`. Mews may derive `project` from `cwd` and preserve a hook `session_id` when provided. Do not read prompts, transcripts, or terminal scrollback by default; task titles require explicit opt-in and are truncated to 80 characters.

## Notification Rules

Implemented default behavior:

- `needs_input`: notify immediately.
- `failed`: notify immediately.
- `done`: notify immediately.
- `running`: update menu bar only.
- `idle`: update menu bar only.

Deduping, runtime thresholds, and quiet mode remain post-MVP notification policy work.

## Security and Privacy

Mews should make privacy boring and auditable.

Hard boundaries:

- No network requests for core functionality.
- No telemetry in MVP.
- No prompt, transcript, or code capture by default.
- Prompt-derived task titles require explicit opt-in, are truncated, and stay local.
- No terminal scrollback scraping by default.
- No shell command execution from received events.
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

- Menu bar agent installed.
- LaunchAgent loaded.
- Unix socket reachable.
- Notification permission granted.
- Mews store writable.
- Claude Code integration installed and reachable.
- Codex integration installed or marked fallback.
- Copilot CLI hook status.
- Integration rollback state.

Example:

```text
Mews Doctor

Agent              running
Socket             reachable
Notifications      authorized
Claude Code        enabled
Codex              enabled
Copilot CLI        hooks installed
Store              writable

No action needed.
```

## Packaging

The release package and future Homebrew formula install:

```text
bin/mw
libexec/Mews.app
```

`mw setup` should:

1. Ensure `libexec/Mews.app` exists.
2. Discover supported tools.
3. Show every planned write.
4. Write backups before editing tool config.
5. Record rollback state.

`mw start` should:

1. Verify setup exists.
2. Install `~/Library/LaunchAgents/dev.mews.agent.plist`.
3. Launch the app.
4. Verify IPC.

This keeps the install path simple while still using a proper app bundle for menu bar identity and macOS notifications.

`make build` produces universal `arm64` and `x86_64` CLI and app executables. `make package` produces a versioned tarball and SHA-256 checksum. `VERSION=vX.Y.Z make release-check` runs tests, lint, checksum verification, and an isolated installed-runtime smoke that applies setup, executes all three generated integration paths through IPC, checks privacy-safe history, and verifies undo/reset. Formal `make release` must run from a clean `main` synchronized with `origin/main` and requires a Developer ID identity and notarization keychain profile. It signs the CLI and app, submits the app for notarization, staples the ticket, verifies with Gatekeeper, creates the release archive, and generates a checksum-pinned Homebrew formula for tap publication. Homebrew-managed hooks and LaunchAgent paths use the stable `opt/mews` prefix rather than a versioned Cellar path.

## Technology Choice

Mews should use Go as the primary implementation language.

Go owns:

- CLI commands.
- Setup, doctor, undo, and rollback.
- Tool detection and integration management.
- Local store and event validation.
- Unix socket IPC.
- `mw notify` and `mw run`.
- Release binaries and Homebrew packaging.

`Mews.app` should stay thin. The init-preview app is a small Swift/AppKit LSUIElement app that owns the menu bar icon and recent event UI while reusing the Go helper for local IPC. If a pure-Go menu bar implementation proves reliable enough, it can be considered, but the architecture should not force the product into a non-native Mac UX just to keep one language.

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
  notify/
  store/
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
4. **Makefile is the contributor API**: common tasks should be discoverable through `make test`, `make build`, `make lint`, `make package`, and `make install-local`.
5. **Security docs are first-class**: because Mews edits local tool configs, it needs `SECURITY.md` and a practical `SECURITY_AUDIT.md` from the start.
6. **Workflows stay boring**: CI runs tests, lint, shellcheck, CodeQL, package checksum verification, and an isolated artifact smoke. Signing remains an explicit credential-gated maintainer action.

Makefile targets:

```text
make build          # Build mw CLI and package Mews.app
make test           # Run Go tests
make lint           # Run Go lint and shellcheck
make package        # Produce local release artifact
make release        # Sign, notarize, verify, and package a release
make install-local  # Install into a local test prefix
make clean          # Remove build outputs
```

Workflows:

```text
check.yml           # formatting, lint, shellcheck
test.yml            # Go tests
codeql.yml          # CodeQL scan
package.yml         # build, checksum, and artifact smoke
```

The goal is the same feeling as Mole: a serious local Mac utility with simple commands, visible safety boundaries, and a repository that does not feel over-engineered.

## Verification Plan

Manual acceptance checks:

1. Fresh install, run `mw start`, menu bar icon appears.
2. `mw start` discovers installed tools and asks before writing integrations.
3. `mw doctor` reports green state after setup.
4. `mw notify --status done --message "Task finished"` updates menu bar and history.
5. `mw run -- false` produces a failed event.
6. Claude Code notification hook reaches Mews without exposing transcript content.
7. `mw undo` restores backed-up config and removes Mews-owned files.
8. With notifications denied, menu bar status still works and doctor explains the permission.
9. With the agent stopped, `mw notify` either starts it or gives a clear error.
10. With malformed third-party config, Mews refuses to edit and leaves the file unchanged.

Automated tests:

- Event validation.
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
| shell wrapper or alias suggestion | remove generated Mews-owned file |
| Mews store | keep by default, delete with explicit reset command |

`mw undo` should not delete event history unless the user runs a separate reset command.

## Open Questions

1. Copilot CLI lifecycle hook coverage needs real-session verification beyond `agentStop`, `sessionEnd`, and `errorOccurred`.
2. Claude Code and Codex integrations need real-session compatibility checks as upstream payloads evolve.
3. The Homebrew tap layout must preserve the signed app bundle and checksum verification.

These do not block the first architecture because each has a safe fallback.
