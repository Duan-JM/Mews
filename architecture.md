# Mews Architecture

## Product Goal

Mews is a local macOS companion for terminal AI agents. The first public version should feel like this:

```bash
brew install mews
mews start
```

After that, Mews starts a menu bar companion, finds supported AI tools, enables local notifications where it can, and keeps a recent status history. Users should not need to edit Claude Code, Codex, Copilot CLI, or tmux configuration by hand.

## Non-Goals

- No cloud service.
- No account system.
- No team dashboard.
- No AI chat UI.
- No transcript sync.
- No terminal scrollback scraping by default.
- No App Store product architecture in the first version.
- No notch cat as a required MVP dependency.

## Design Principles

1. **Install, start, done**: the main path is `brew install mews` and `mews start`.
2. **Menu bar first**: status must be visible even if notifications are missed.
3. **Local-only**: all state stays under the current macOS user account.
4. **No surprise writes**: Mews explains what it will enable, writes backups, and can undo its own changes.
5. **Fail honestly**: unsupported tools show as unsupported, not silently broken.
6. **Advanced paths stay advanced**: `mews notify`, wrappers, and hook details exist, but do not lead the product.

## System Overview

```text
                  ┌────────────────────┐
                  │      mews CLI       │
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

1. **`mews` CLI**: user-facing command installed by Homebrew.
2. **Mews Menu Bar Agent**: a native macOS LSUIElement app launched by `mews start`.

The CLI handles setup, diagnostics, undo, and scriptable events. The agent owns the menu bar icon, notification delivery, current state, recent history, and local IPC server.

## Runtime Components

### 1. `mews` CLI

Responsibilities:

- Start and stop the menu bar agent.
- Detect installed tools.
- Install and remove integrations.
- Send custom events with `mews notify`.
- Wrap commands with `mews run -- <command>`.
- Run diagnostics with `mews doctor`.
- Revert changes with `mews undo`.

Recommended commands:

```bash
mews start      # Start agent and enable supported tools
mews status     # Print current watched tools and agent state
mews listen     # Listen in the terminal and print events as they arrive
mews doctor     # Diagnose permissions, hooks, LaunchAgent, and IPC
mews stop       # Stop the local agent
mews undo       # Remove Mews-installed integrations and restore backups

mews notify     # Advanced: send a custom event
mews run -- cmd # Advanced: run a command and report completion
```

### 2. Mews Menu Bar Agent

Responsibilities:

- Render current state in the menu bar.
- Show recent event history.
- Deliver macOS notifications.
- Receive local events from integrations and the CLI.
- Apply notification rules, deduping, and quiet periods.
- Persist recent events and settings.

The agent should be packaged as a small app bundle so macOS notifications, icon identity, and login behavior are reliable.

### 3. Integration Manager

Responsibilities:

- Discover installed tools.
- Decide the safest available integration for each tool.
- Install integration files with backups.
- Verify that integrations can call back into Mews.
- Report unsupported or partially supported tools to `mews doctor`.

Supported tools in the first version:

| Tool | First strategy | Fallback |
|---|---|---|
| Claude Code | Install local hook command after confirmation | Show manual instructions in `mews doctor` |
| Codex | Use notify command or config-backed hook after confirmation | Suggest `mews run -- codex` |
| Copilot CLI | Use wrapper because hooks may not exist | Show wrapper alias suggestion |
| tmux | Optional status watcher or wrapper-based reporting | `mews run -- <command>` |
| Custom scripts | `mews notify` | None |

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
  mews.log

~/Library/LaunchAgents/
  dev.mews.agent.plist
```

Storage format:

- `config.json`: user preferences and notification rules.
- `events.jsonl`: append-only recent event log, capped by size or age.
- `integrations.json`: installed integration records and backup paths.
- `backups/`: original config files before Mews modifies them.

SQLite can wait. JSON and JSONL are easier to inspect, back up, and repair in the first version.

## Data Flow

### `mews start`

```text
User runs mews start
  │
  ├─ Ensure Application Support and Logs directories exist
  ├─ Install or refresh LaunchAgent for the menu bar agent
  ├─ Launch menu bar agent
  ├─ Discover Claude Code, Codex, Copilot CLI, tmux
  ├─ Show planned integrations
  ├─ Ask for approval before writing tool configs
  ├─ Install supported integrations with backups
  ├─ Send test event through local IPC
  └─ Print watched tools and next action
```

Expected output:

```text
Mews is watching:
  ✓ Claude Code
  ✓ Codex
  ✓ Copilot CLI
  ✓ tmux

Menu bar companion started.
Run `mews doctor` if something does not notify correctly.
```

### Agent Event Delivery

```text
AI tool event
  │
  ├─ hook, wrapper, or mews notify
  │
  ▼
mews CLI validates event
  │
  ▼
Unix domain socket
  │
  ▼
Menu bar agent
  │
  ├─ update current status
  ├─ append to events.jsonl
  ├─ dedupe repeated events
  └─ show notification if needed
```

### `mews undo`

```text
User runs mews undo
  │
  ├─ Read integrations.json
  ├─ Restore every backed-up file
  ├─ Remove generated hook or wrapper files
  ├─ Unload LaunchAgent if requested
  ├─ Stop menu bar agent if requested
  └─ Print restored items
```

Rollback is part of the product, not a debug feature.

## Event Model

Mews should keep the event model small.

```json
{
  "version": 1,
  "source": "claude-code",
  "session_id": "abc123",
  "project": "Mews",
  "status": "done",
  "message": "Task finished",
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
- `project`
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

The message should be short and safe. Integrations should avoid sending prompts, code snippets, or transcript content by default.

## IPC

Use a Unix domain socket under the user Application Support directory:

```text
~/Library/Application Support/Mews/mews.sock
```

Reasons:

- Local to the user.
- No port collisions.
- No localhost firewall prompt.
- Easy for CLI and hook scripts to reach.

If the socket is missing, `mews notify` should try to start the agent once, then fail with a clear doctor hint.

## Integration Strategy

### Claude Code

Use Claude Code hooks when available. Mews should install a small command hook that calls `mews notify` with only status metadata.

Rules:

- Back up existing settings before editing.
- Preserve user hooks.
- Add a Mews-owned block with a stable marker.
- Remove only the Mews-owned block in `mews undo`.

### Codex

Use the supported notify or hook path when present. If the installed Codex version does not expose a stable notify path, Mews should not edit unknown config. It should mark Codex as partially supported and suggest wrapper mode.

### Copilot CLI

Start with wrapper mode unless a stable lifecycle hook exists.

Mews can offer:

```text
Copilot CLI found.
Native hooks were not detected.
Use `mews run -- copilot` for completion and failure notifications.
```

Do not pretend Copilot is deeply integrated until the integration can detect needs-input, done, and failed reliably.

### tmux

First version should not scrape pane content. Use explicit wrapper commands and optional status integration.

Safe first version:

- `mews run -- <long command>`
- optional tmux status item showing Mews state

Avoid in MVP:

- reading scrollback
- parsing arbitrary terminal output
- watching every pane automatically

## Notification Rules

Default behavior:

- `needs_input`: notify immediately.
- `failed`: notify immediately.
- `done`: notify only if runtime is longer than a small threshold, for example 10 seconds.
- `running`: update menu bar only.
- `idle`: update menu bar only.

Deduping:

- Collapse repeated events with the same `source`, `session_id`, and `status` inside a short window.
- Keep the newest event visible in the menu bar.

Quiet mode:

- A menu bar toggle can silence banners while keeping history and status.
- Critical states still update the menu bar.

## Security and Privacy

Mews should make privacy boring and auditable.

Hard boundaries:

- No network requests for core functionality.
- No telemetry in MVP.
- No prompt, transcript, or code capture by default.
- No terminal scrollback scraping by default.
- No shell command execution from received events.
- No broad write access beyond known integration files and Mews-owned paths.

Config writes:

- Show what will be changed.
- Write backups before edits.
- Use stable markers around Mews-owned blocks.
- Support `mews undo`.
- Refuse to edit malformed config files and explain through `mews doctor`.

## Doctor

`mews doctor` is a first-class user experience.

It should check:

- Menu bar agent installed.
- LaunchAgent loaded.
- Unix socket reachable.
- Notification permission granted.
- Mews store writable.
- Claude Code integration installed and reachable.
- Codex integration installed or marked fallback.
- Copilot CLI wrapper status.
- tmux support status.
- Recent event delivery test.

Example:

```text
Mews Doctor

Agent              running
Socket             reachable
Notifications      allowed
Claude Code        enabled
Codex              enabled
Copilot CLI        wrapper suggested
tmux               enabled
Store              writable

No action needed.
```

## Packaging

Homebrew should install:

```text
bin/mews
libexec/Mews.app
```

`mews start` should:

1. Ensure `libexec/Mews.app` exists.
2. Install `~/Library/LaunchAgents/dev.mews.agent.plist`.
3. Launch the app.
4. Verify IPC.

This keeps the install path simple while still using a proper app bundle for menu bar identity and macOS notifications.

## Technology Choice

Mews should use Go as the primary implementation language.

Go owns:

- CLI commands.
- Setup, doctor, undo, and rollback.
- Tool detection and integration management.
- Local store and event validation.
- Unix socket IPC.
- `mews notify` and `mews run`.
- Release binaries and Homebrew packaging.

`Mews.app` should stay thin. The first version can be a small native macOS app that owns the menu bar icon, notification identity, and recent event UI. If a pure-Go menu bar implementation proves reliable enough, it can be considered, but the architecture should not force the product into a non-native Mac UX just to keep one language.

Do not use Rust in the first version. Mews needs simple distribution, fast iteration, and boring local tooling more than Rust's extra safety guarantees.

## Minimal Implementation Shape

Recommended structure:

```text
cmd/
  mews/
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
go.sum
Makefile
install.sh
README.md
SECURITY.md
SECURITY_AUDIT.md
architecture.md
```

Repository rules:

1. **Root stays product-facing**: README, install script, architecture, security docs, and Makefile should be enough for a new contributor to understand the project.
2. **Go code follows `cmd/` + `internal/`**: no sprawling packages at root.
3. **Scripts are explicit**: build, package, release, and local install scripts live under `scripts/`; `install.sh` stays as the user-facing fallback installer.
4. **Makefile is the contributor API**: common tasks should be discoverable through `make test`, `make build`, `make lint`, `make package`, and `make install-local`.
5. **Security docs are first-class**: because Mews edits local tool configs, it needs `SECURITY.md` and a practical `SECURITY_AUDIT.md` from the start.
6. **Workflows stay boring**: CI should run tests, lint, shellcheck for scripts, CodeQL, and release packaging. Do not add complex release automation before the first stable package exists.

Suggested Makefile targets:

```text
make build          # Build mews CLI and package Mews.app
make test           # Run Go tests
make lint           # Run Go lint and shellcheck
make package        # Produce local release artifact
make install-local  # Install into a local test prefix
make clean          # Remove build outputs
```

Suggested workflows:

```text
check.yml           # formatting, lint, shellcheck
test.yml            # Go tests
codeql.yml          # CodeQL scan
release.yml         # tagged release artifacts
```

The goal is the same feeling as Mole: a serious local Mac utility with simple commands, visible safety boundaries, and a repository that does not feel over-engineered.

## Verification Plan

Manual acceptance checks:

1. Fresh install, run `mews start`, menu bar icon appears.
2. `mews start` discovers installed tools and asks before writing integrations.
3. `mews doctor` reports green state after setup.
4. `mews notify --status done --message "Task finished"` updates menu bar and history.
5. `mews run -- false` produces a failed event.
6. Claude Code notification hook reaches Mews without exposing transcript content.
7. `mews undo` restores backed-up config and removes Mews-owned files.
8. With notifications denied, menu bar status still works and doctor explains the permission.
9. With the agent stopped, `mews notify` either starts it or gives a clear error.
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

`mews undo` should not delete event history unless the user runs a separate reset command.

## Open Questions

1. Copilot CLI lifecycle hooks need verification. Until then, wrapper mode is the official design.
2. Codex notify support should be detected by version and config shape, not assumed.
3. The exact Homebrew formula layout should be checked against the final app bundle signing and notification behavior.

These do not block the first architecture because each has a safe fallback.
