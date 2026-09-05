# Mews Architecture

## Product Goal

Mews is a local macOS companion for terminal AI agents. The first public version should feel like this:

```bash
brew install --cask mews
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

1. **Install, setup, start, undo**: the main path is `brew install --cask mews`, `mw setup`, `mw start`, and `mw undo`.
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

1. **`mw` CLI**: user-facing command installed from a verified release package or the Homebrew Cask.
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
- Show prioritized recoverable sessions and bounded history-only events.
- Present confirmed degraded or blocked runtime health with a copyable recovery instruction.
- Route each attention event to the physical-notch shell or a macOS notification fallback.
- Receive local events from integrations and the CLI.
- Deliver native notifications for implemented attention states when no physical notch can present them.
- Return to a validated source terminal context when possible, or open the configured terminal working directory.
- Copy a Mews-owned session history command from notification or panel actions.
- Persist recent events and settings.

The agent is packaged as a small app bundle so macOS menu bar identity, notification permission, and local visibility are reliable. It starts the bundled `mw agent` helper, renders a state-responsive template pixel logo, reads local session and event state for the context menu, opens a compact notch/top-center shell, and routes attention events through either the physical-notch shell or native notifications. Before launching a child and after a child exits, the app asynchronously pings the same Unix socket path used by the Go store resolver, including the private short-path and namespace fallback. In-flight probes are deduplicated so the main actor never waits on IPC. A responsive external agent is treated as healthy, is never duplicated, and is not terminated when the app exits. While externally owned, liveness is checked by the existing two-second refresh. A missing helper, launch failure, or short-lived child uses monotonic exponential restart delays from 10 seconds to a five-minute cap. One minute of healthy child runtime resets the delay, which avoids a persistent process-launch loop while retaining automatic recovery.

The shell keeps a pure `closed` / `peek` / `expanded` interaction policy separate from AppKit timers and event monitors. On a physical notch, `closed` is a persistent compact strip below a hardware-width neck, `peek` is a bounded wider status preview, and `expanded` is the existing full panel. The top-center fallback still renders only `expanded`. AppKit owns the fixed 420×220 nonactivating panel, display placement, passive local/global mouse observation, and teardown. Hit testing derives from the current rendered shell frame rather than the transparent maximum panel, so the visible compact strip, preview, and expanded surface match their click and hover targets. Outside clicks close an expanded panel without consuming or synthesizing the target event. SwiftUI keeps the solid black shell for a physical notch and uses rounded adaptive material with a native window shadow for top-center placement. The fallback sits six points below the visible menu-bar edge. Left-clicking the status item toggles the shell, while right-click and Control-click preserve the existing event, Refresh, and Quit menu. Physical-notch hover is optional: if global hover monitoring is unavailable, the app logs the degradation and keeps the status-item click and top-center fallback paths.

Display placement is recalculated on `NSApplication.didChangeScreenParametersNotification`. The resolver prefers any available physical notch, otherwise uses the main display's `visibleFrame` top center so the shell stays below the menu bar. This covers external-display, clamshell, resolution, coordinate, and main-screen changes. A transient empty screen list clears placement, closes the interaction state, and orders the panel out; the next display notification restores compact placement without reopening the expanded panel. The panel remains stationary, joins all Spaces, and participates as a full-screen auxiliary window.

Alert routing reads that live placement for every newly alertable semantic session transition. Only the current transition that the physical notch will actually present suppresses its system notification; other transitions keep Notification Center fallback so a two-second reload batch cannot silently drop an earlier completion. Without a physical notch, presentation state still updates the menu bar and top-center shell content, but the shell does not auto-open for the transition.

New presentation changes can show a bounded preview without collapsing an expanded shell. Startup history is synchronized silently, so relaunching Mews does not replay stale attention or completion peeks. `needs_input` and `failed` preview for 4 seconds, while `done` previews for 2.5 seconds. Each then returns to the compact `ASK`, `FAIL`, or `DONE` state until normal presentation freshness changes the status. Attention previews are deduplicated by the presentation transition identifier. `running` and `idle` stay compact and do not auto-preview.

Presentation selection uses an injected current time rather than mutating stored history. `running` and `needs_input` events remain current for 24 hours; settled `done`, `failed`, and explicit `idle` events remain current for 30 minutes. Events more than five minutes in the future are not selected as current. When the latest primary event expires, the status logo returns to `idle`, automatic peeks close, and current attention resolves. Expired primary events remain in bounded local history but do not occupy the expanded active-session panel; events without stable identity keep their separate bounded menu entries.

The same centralized freshness policy applies to the recoverable session index. Repository updates and explicit history recovery reject evidence beyond the five-minute future tolerance. A valid current event may replace an already persisted too-future record so clock-skewed evidence cannot block the session until its timestamp arrives. Expiry is derived at read time with an injected clock: it changes the reported status to `idle` without rewriting the accepted evidence, the session index, or `events.jsonl`. Presentation derives a separate presence value from the latest source and hook event. Any case-insensitive `sessionEnd` is closed; other Claude Code and Copilot CLI lifecycle hooks are open. Codex `SessionStart`, `UserPromptSubmit`, and `Stop` are open, while legacy `agent-turn-complete`, runner, and hookless records remain unknown. No persisted schema migration is required because existing records already retain `hookEvent`.

A pure attention reconciler maps the current session collection into stable attention rounds. A round key contains the stable `source` plus `session_id` identity, semantic status, and `statusChangedAt`; it never uses a JSONL row, file offset, or random request identifier. Reconciliation returns newly alertable rounds, resolved rounds, the active count, and stable Notification Center identifiers. Delivered, acknowledged, and resolved state is persisted before routing, so duplicate hooks, replay, rotation, and restart do not redeliver a handled round. Returning to `running` or `idle`, expiry, or a later semantic round resolves the older attention and requests removal of matching pending and delivered notifications.

`SessionPresentationPolicy` combines the recoverable session index, semantic attention disposition, and fresh runtime health into one native presentation model. Before presence filtering, sessions with validated return metadata are collapsed to the newest evidence for each tmux pane or kitty window, so an interrupted session cannot remain beside its replacement while independent terminal slots stay visible. Explicitly closed sessions are excluded immediately, including when their newer evidence supersedes an older open record in the same terminal slot. Known-open sessions remain displayable between turns for up to 24 hours, with `done` and open `idle` evidence presented as `STOP`; unknown-presence sessions remain only while their status is fresh, so a stopped Codex or runner row expires after 30 minutes. Rows are ordered by `needs_input`, `failed`, `running`, unacknowledged stopped, then acknowledged stopped state. Evidence time and stable identity break ties deterministically. The fixed 420×220 expanded shell keeps every displayable row in a native vertical scroll view, while the context menu remains capped at five sessions. Events without a stable session identity remain bounded history-only entries instead of receiving fabricated session actions. Session recovery has an independent read-and-reconcile fallback, so corrupt attention state disables alert routing without also hiding valid navigation targets.

Each session row shows a bounded agent label, project label, eight-column session reference, semantic status, and its own Return and Copy controls. The model never exposes the full session identifier or working directory. Panel and menu actions receive `CLIContextPayload` only after the existing validation path marks it actionable. **Return** delegates to `CLIContextOpener.open` and acknowledges only that session's current attention, while **Copy** delegates to `CLIContextOpener.copy` without acknowledging; no event-provided command is executed. While the shell is expanded, the controller retains the relative order of identities that remain available and appends new identities after them. Closed or otherwise removed identities leave the list immediately instead of retaining stale action slots.

The status item uses a monochrome template image so system menu bar contrast remains authoritative. `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` refreshes panel rendering when Reduce Motion, Reduce Transparency, or Increase Contrast changes. Reduce Motion selects static logo poses and opacity-only shell transitions without changing layout. Reduce Transparency and Increase Contrast replace top-center material with an opaque appearance-aware surface; Increase Contrast also raises secondary-copy, separator, border, status, and disabled-control contrast. The physical-notch shell remains solid black. The status item, panel window, shell container, summaries, and buttons expose accessibility labels or native text for VoiceOver; these adaptations do not add a Mews permission prompt.

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
| Codex | Install trusted user-level lifecycle hooks after confirmation | Use `mw run -- <command>` for unsupported versions |
| Copilot CLI | Install user-level hooks in `~/.copilot/hooks/mews.json` | `mw run -- copilot` for process-exit fallback |
| Custom scripts | `mw notify` | None |

### 4. Local Store

The store is local and user-scoped.

Recommended paths:

```text
~/Library/Application Support/Mews/
  config.json
  events.jsonl
  sessions.json
  attention.json
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
- `sessions.json`: versioned recoverable current-session index derived from accepted events.
- `attention.json`: minimal versioned delivery and acknowledgement state for the latest semantic round per session.
- `integrations.json`: installed integration records and backup paths.
- `backups/`: original config files before Mews modifies them.
- `copilot-hooks/`: opaque hashes and pending-stop markers used to correlate Copilot subagent lifecycle events.

The socket normally lives in Application Support. If the full path would exceed the macOS Unix socket limit, Mews uses a private `0700` directory under the system temporary directory for the current user.

SQLite can wait. JSON and JSONL are easier to inspect, back up, and repair in the first version.

The session index uses `source` plus a non-empty `session_id` as its stable identity. Events without a session ID remain available in history but never enter current session state. Each record keeps the accepted status, status-change time, latest evidence time, source, project, hook event, and validated terminal-return metadata. New accepted evidence retains the previous non-empty project and merges validated return metadata field by field when optional fields are omitted, while newer non-empty values replace matching fields. The merged context is reconstructed through `CLIContextPayload`, so a terminal-profile change removes incompatible kitty metadata while retaining still-valid fields such as `cwd`. The hook event always belongs to the latest evidence and is never inherited. Mews-owned history commands are regenerated from the identity and current CLI location rather than persisted as command text.

The fold is incremental and deterministic. Older evidence and duplicate event IDs are ignored; legacy events without IDs include their exact timestamp in the fallback evidence identity. Equal-time evidence uses a centralized precedence policy so explicit session end, idle, and runner process-exit evidence cannot be replaced by a less conclusive update merely because it arrived later. Persisted precedence must match that same policy for the stored identity, status, and hook. Main-agent, subagent, and recoverable rules remain the same as notification and primary presentation rules: subagent and recoverable events stay in history and do not replace current primary state.

`SessionStateController` is the only runtime owner of `SessionStateRepository`.
It produces immutable snapshots for attention and presentation consumers; those
consumers never construct or save `sessions.json`. The controller serializes
folds and store writes, and publishes a new snapshot only after the copy-on-write
save succeeds. It also owns a reconciliation anchor for the event log. The
controller scans from that uncommitted anchor on every reconciliation, so a
failed save retries the same evidence on the next refresh. The anchor advances
only with a stable, complete-line scan and a successful fold transaction. Each
controller scan stops at the foreground reader's published boundary so
attention, notifications, and presentation consume one event generation.

Evidence ordering is append-stable. Persisted records retain an optional global
evidence ordinal and a bounded same-timestamp/same-precedence tie set. Older
snapshots without ordering metadata enter a rebuild gate and remain usable for
display, but ordering-dependent operations fail open until a complete event-log
scan proves their order. If the tie set exceeds its bounded capacity, the
record freezes that ordering key; only strictly newer evidence can establish a
new order. Full resyncs fold into a separate ordered projection before merging
with persisted records; an equal-key winner absent from the available log
remains visible with unknown ordering rather than being replaced by an
unproven replay. This prevents rotation or restart from changing a winner.

Active-session dismissal is an evidence-scoped compare-and-set. A record may
persist `dismissedEvidenceID` only when it matches the current ordered,
non-overflow evidence; missing, stale, running, closed, expired, or
ambiguous-order records remain visible or return an explicit non-success
result. The controller scans unseen evidence to stable EOF before each
dismissal transaction, saves the folded index before advancing its anchor, and
publishes the resulting immutable snapshot. Strictly newer primary evidence
clears the dismissal; replayed, older, subagent, and recoverable evidence does
not.

The expanded session list keeps SwiftUI row content inside its AppKit-backed
`NSScrollView`. A custom mouse recognizer delays primary-button delivery only
for dismissible rows, preserving ordinary Return and Copy clicks below the
eight-point drag slop. Precise trackpad events are buffered until the same
eight-point and 1.25 direction lock resolves. Horizontal sequences drive the
swipe state machine; vertical sequences replay their complete buffered events
to native scrolling. Physical deltas are normalized against the user's Natural
Scrolling preference, and momentum never commits a dismissal.

`SessionListPresentationModel` owns one interactive row plus independent
removal tokens. Rows are keyed by stable session identity and evidence ID, so a
refresh cannot redirect a gesture to a replacement row; replacement evidence
keeps the prior identity's expanded-list position. Controller revisions reject
pre-dismissal snapshots, while a changed identity/evidence target cancels the
gesture and adopts the latest state. Successful writes animate the captured row
from its current offset before compacting its height. An animatable observer
finalizes the normal path at the visual endpoint, with a bounded 380 ms
watchdog only for interrupted callbacks; failures keep the row visible and
retryable. Panel close, `orderOut`, placement loss, and app shutdown advance the
interaction epoch and cancel pending visual callbacks. Drag updates change
only row transform, clipping, and opacity; event scanning, JSON work, and atomic
persistence remain on the session controller queue.

`EventLogReader` opens the log, stats the same descriptor, reads only complete
JSONL records, and revalidates the descriptor and pathname before publishing a
reload. Its cursor includes observed file mutation metadata plus complete-line
and consumed-prefix digests, so same-inode rewrites are distinguished from
append-only growth. Replacement, truncation, and anchor mismatch provide a full
session resync batch while preserving the existing notification `newEvents`
semantics. Read, decode, reconciliation, and save failures are explicit, leave
the previous cursor unchanged, and keep presenting the last valid persisted
Session snapshot.
`SessionEvidenceReader` uses the same descriptor-bound scanner for controller
ordered scans without advancing the notification reader.

`sessions.json` is written through a private `0600` staging file followed by an atomic rename. Missing storage starts with an empty index. On every controller start, its first independent evidence scan reconciles the complete available event log into the persisted index, including events appended while the app was offline; sessions absent from the scan remain intact. Invalid JSON, unsupported versions, duplicate identities, and invalid persisted records return explicit errors without deleting the damaged file. Persisted return metadata must round-trip exactly through `CLIContextPayload`; forbidden commands, unknown keys, or values that validation would drop make the record corrupt rather than silently reducing its context. Corrupt storage recovery is an explicit rebuild from validated `MewsEvent` values followed by another atomic write.

`attention.json` stores only the latest round key and its delivered, acknowledged, or resolved disposition for each session. It uses the same private staging-file and atomic-rename pattern. Missing state starts empty; invalid JSON, unsupported versions, unknown schema keys, duplicate identities, and inconsistent round identities fail explicitly without deleting or silently rebuilding the file. The app logs the failure, leaves attention routing disabled, and retries the unchanged file on each refresh so a corrected store recovers without restarting Mews.

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
  - install Codex lifecycle hooks: <home>/.codex/hooks.json
  - trust the fixed Mews Codex hooks in: <home>/.codex/config.toml
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
- `launch_context`
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

Return actions open confirmed Codex App sessions with the fixed `codex://threads/<session-id>` deep link. Mews records that context when the Codex hook either inherits the expected desktop originator plus a recognized App resource path or has a process ancestry containing the bundled Codex runtime and its owning App executable. Validated tmux context takes precedence. Unknown Codex origins continue through the terminal fallback instead of being guessed as App sessions.

Terminal return actions copy the Mews-owned history command and activate the source terminal. When an event originates in tmux, the CLI preserves the validated same-user socket and source pane even when no client is attached. If a client is available, the app uses one fixed `switch-client -c <client> -t <pane>` operation so tmux restores the source session, window, and pane together. If the client is absent or disappears before the action, the app verifies the pane with a fixed `display-message` operation. For kitty, it then opens a new active instance that runs a fixed `attach-session -t <pane>` command with inherited tmux variables removed. Kitty window focus is attempted only when the event carries a numeric kitty window ID and an existing local Unix remote-control address; Mews does not enable kitty remote control. A failed exact kitty or detached tmux restore skips generic application activation and opens a new active kitty instance with `--directory <cwd>`, even if kitty is already running. Other unavailable source contexts use the configured terminal at the event's validated absolute `cwd`. A directory-only event does not invent a session command. Mews never executes event-provided command text or reads terminal scrollback.

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

Mews installs user-level Claude Code hooks for `SessionStart`, `UserPromptSubmit`, `PermissionRequest`, `Stop`, `StopFailure`, and `SessionEnd`. Each command calls `mw notify` and receives hook JSON through stdin. `SessionStart` records open-but-stopped presence without notifying, `UserPromptSubmit` records `running`, `Stop` records stopped-between-turns state, and `SessionEnd` closes the active row.

Rules:

- Back up existing settings before editing.
- Preserve user hooks.
- Record the exact Mews commands in `integrations.json`.
- Remove only those exact commands in `mw undo`.

### Codex

Mews installs user-level Codex command hooks for `SessionStart`, `UserPromptSubmit`, `Stop`, and `SessionEnd` in `~/.codex/hooks.json`. Each command calls `mw hook codex <event>` and receives the hook JSON through stdin. `UserPromptSubmit` records `running`, `Stop` records stopped-between-turns state, and `SessionEnd` closes the active row immediately. Hooks launched from Codex App retain a narrow `codex_app` launch marker derived from inherited local environment evidence or the validated local parent-process chain, without reading the transcript.

Codex requires user hook definitions to carry a matching trust hash before they run outside the sandbox. `mw setup --yes` writes a marked `hooks.state` block for only the fixed Mews commands it just installed. `mw doctor` verifies both the hook definitions and their current hashes. Existing user hooks and a user-owned legacy `notify` command are preserved. An older Mews-managed `notify` block is migrated to lifecycle hooks.

### Copilot CLI

Use Copilot CLI user-level hooks when available. Mews should install a Mews-owned hook file at `~/.copilot/hooks/mews.json`, or `$COPILOT_HOME/hooks/mews.json` when `COPILOT_HOME` is set.

Mews can offer:

```text
Copilot CLI found.
User-level hooks installed.
Main-agent completion and failure events will notify Mews.
Subagent completion events will remain silent.
```

The managed hook file routes `sessionStart`, `userPromptSubmitted`, `subagentStart`, `subagentStop`, `agentStop`, `sessionEnd`, and `errorOccurred` through `mw hook copilot <event>`. `userPromptSubmitted` maps to a main-agent `running` event without persisting prompt text unless task-title opt-in is enabled. When `agentStop` arrives with no tracked subagents, it maps directly to a main-agent `done` event. When tracked subagents remain active, it maps to a main-agent `running` event with `subagentRunning` lifecycle evidence; the final `subagentStop` records its silent subagent `done` event and then emits the deferred main-agent `done` event. `sessionEnd` maps to `idle`, and `errorOccurred` maps to `failed` while preserving Copilot's `recoverable` flag.

Some Copilot CLI versions emit lifecycle events while a subagent or nested tool call is active. Those payloads use provider tool-call identifiers such as `call_*` or `toolu_*`; nested `agentStop` may set `transcriptPath` to null, while the later primary stop can reuse the subagent transcript path. Mews suppresses lifecycle events with tool-call identifiers and hook-provided subagent names without using transcript paths to classify the primary stop. Supported subagents are tracked by opaque transcript-path hashes under a per-session file lock. State transition and event delivery share that lock, and deferred completions retain a stable event ID until delivery succeeds, so concurrent or uncertain retries cannot reorder the final primary state or notify twice. Resumed prompts or errors cancel a stale deferred completion before it can replace newer primary state, and orphaned active markers expire with the 24-hour active-session safety cap. Copilot's built-in `general-purpose` agent does not emit subagent lifecycle hooks, so Mews retains the provider's main-turn stop behavior for that agent instead of guessing. Correlation state is cleared on session start, session end, and `mw undo`; undo also disables late in-flight hook writes until the next successful Copilot setup. Raw transcript paths and transcript contents are never stored.

Mews may derive `project` from `cwd` and preserve a hook `session_id` when provided. Do not read prompts, transcripts, or terminal scrollback by default; task titles require explicit opt-in and are truncated to 80 characters.

## Notification Rules

Implemented default behavior:

- Primary-agent `needs_input`: show a four-second physical-notch preview and retain compact `ASK`, or notify immediately when no physical notch is available.
- Primary-agent non-recoverable `failed`: show a four-second physical-notch preview and retain compact `FAIL`, or notify immediately when no physical notch is available.
- Primary-agent `done`: show a 2.5-second physical-notch preview and retain compact `DONE`, or notify immediately when no physical notch is available.
- Primary-agent stop with tracked Copilot subagents: retain a `SUB` / `Subagent Running` row without notifying; notify once after the final tracked subagent stops.
- Subagent events and recoverable errors: keep in history without notifying or replacing primary status.
- `running`: update menu bar only.
- `idle`: update menu bar only.

Notifications are delivered by the app bundle, which declares the Mews icon so Notification Center can show Mews identity. The logo is app identity only, not a notification attachment.

Action behavior:

- **Return to CLI**: acknowledge only the owning session's current attention, copy the local session history command, then restore a validated source terminal, attach a new kitty window to a detached tmux target, or open the configured terminal at the event directory.
- **Copy Return Command**: copy only the Mews-generated session history command without acknowledging attention.
- Default notification clicks use the same session-scoped acknowledgement and open action.
- Relative, missing, and non-directory paths are never opened.

Runtime thresholds and configurable quiet mode remain post-MVP notification policy work.

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

## Runtime Health

The Go runtime evaluates setup, event and agent-log write access, the app bundle, LaunchAgent presence and load state, functional IPC responsiveness, notification authorization, and integration drift through one pure policy. It writes a versioned `runtime-health.json` snapshot under Application Support. `mw status`, `mw doctor`, and Mews.app read that snapshot directly. The native presentation ignores `checking`, `ready`, and stale snapshots. A fresh `degraded` or `blocked` state selects the highest-severity affected capability, reports how many additional capabilities are affected, and exposes its recovery text as a copy action when present.

The policy has four states:

- `checking`: a proposed degradation or recovery has not passed two consecutive matching checks yet.
- `ready`: every configured capability is available.
- `degraded`: Mews still provides core event delivery, but an optional capability or one integration is affected.
- `blocked`: local state, setup, the app bundle, or functional IPC prevents core operation.

The first observation without history is immediate. Later changes in either direction require two consecutive matching observations; a return to the stable state cancels the pending transition, and a different target restarts confirmation. An expired pending transition keeps its last stable source but restarts at one matching observation. The snapshot records transition source, target, and count. Overall state uses highest severity: confirmed `blocked` or `degraded` capabilities outrank another capability's pending `checking` transition. The local agent checks every two seconds; CLI health commands also check before printing. Healthy output omits repair actions. Unhealthy output includes only affected capabilities and distinguishes configuration failures from functional failures. Recovery actions never edit third-party configuration automatically.

`NotificationManager` owns a 30-second local timer that calls `getNotificationSettings` while Mews.app is alive. It atomically writes authorization plus `checked_at`. The Go reader distinguishes missing, unreadable, invalid, stale, denied, undecided, unknown, and authorized records. A record older than 90 seconds is stale, allowing temporary timer delays without leaving old authorization trusted indefinitely.

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
- Codex hooks installed and trusted.
- Copilot CLI hook status.

Example:

```text
Mews Doctor

Runtime health: Ready — All configured runtime capabilities are available.

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
Codex              hooks installed and trusted
Copilot CLI        hooks installed
```

## Packaging

The release archive contains:

```text
bin/mw
libexec/Mews.app
```

The fallback installer writes only beneath `PREFIX` and does not edit shell startup files. Users of a custom prefix must expose `PREFIX/bin` through their shell configuration.

The Homebrew Cask moves the app to `/Applications/Mews.app` and links its bundled `Contents/Resources/mw` executable into Homebrew's `bin` directory. The CLI resolves the containing app bundle after following that symlink, so setup hooks keep a stable path across Cask upgrades. Public preflight builds are ad-hoc signed and require an explicit quarantine removal after each install or upgrade; the Cask never performs that bypass automatically.

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

`make build` produces universal `arm64` and `x86_64` CLI and app executables, then applies a complete ad-hoc signature to the local app bundle so menu bar identity and notification permission work during development. `make package` produces a versioned tarball and SHA-256 checksum. `VERSION=v0.1.0-dev.1 make cask-local` creates an ignored local tap and a development-only Cask that removes quarantine after installation because ad-hoc signatures cannot pass Gatekeeper; that Cask must never be published. Setup and undo remain explicit.

`VERSION=vX.Y.Z make release-check` runs tests, lint, checksum verification, the isolated package runtime smoke, and a real Homebrew Cask install/runtime/uninstall smoke. Formal `make release` must run from a clean `main` synchronized with `origin/main` and requires a Developer ID identity and notarization keychain profile. It replaces the local signature with Developer ID signatures, submits the app for notarization, staples the ticket, verifies with Gatekeeper, creates the release archive, verifies the normally quarantined Cask installation with Gatekeeper, and generates a checksum-pinned Cask for tap publication.

`make preflight-release` accepts only `v0.0.N`, runs from the exact public `main` commit, builds the ad-hoc signed archive, and generates a checksum-pinned `mews.rb` without a quarantine-removal stanza. A push to `main` runs `.github/workflows/release.yml`, derives that version from the newest `CHANGELOG.md` release section, and calls `make publish-release`. Publication creates or resumes the matching tag and GitHub Prerelease, downloads every public asset for bytewise comparison, installs the remote Cask with explicit test-only quarantine removal, and updates `Duan-JM/homebrew-mews`. An existing tag that points elsewhere is a hard failure. Tap publication uses an SSH deploy key whose write scope is limited to that tap.

`make screenshots` is a developer-only documentation path. It compiles an explicit set of production UI model and view sources together with synthetic fixtures and a renderer under `scripts/`, writes into temporary directories, and renders fixed 420-by-220-point scenes at 2x resolution. The fixtures cover physical-notch and top-center placement in light and dark appearance. The command validates the fixture manifest, dimensions, file set, current username and HOME exclusions, prohibited sensitive-text markers, and expected visible labels through the macOS Vision framework. It renders twice and requires byte-identical PNG output before replacing `assets/screenshots` through a rollback-protected directory swap. The app build still compiles only `internal/app/macos/*.swift`, and the release package does not copy `scripts/`, so the fixture and renderer never enter Mews.app or the installed runtime. Only the validated documentation PNGs remain under `assets/`.

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
4. **Makefile is the contributor API**: common tasks should be discoverable through `make lint-tools`, `make hooks`, `make check`, `make test`, `make build`, `make lint`, `make package`, `make cask-local`, `make cask-smoke`, and `make install-local`.
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
make cask           # Produce a release archive and versioned Homebrew Cask
make cask-local     # Build a prerelease and prepare an ignored local tap
make cask-smoke     # Install, run, and uninstall an isolated local Cask
make preflight-release # Build publishable preflight artifacts
make release        # Sign, notarize, verify, and package a release
make publish-release # Publish or resume the current main release
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
12. A Copilot subagent completion stays in history without triggering a native notification or replacing primary status; a deferred main completion notifies only after the final tracked subagent stops.
13. The pixel logo opens the compact notch/top-center shell, while right-click and Control-click retain the existing menu.
14. A physical-notch attention event does not also send a system notification; clamshell and no-notch layouts keep the notification fallback.
15. A physical notch keeps a recognizable compact status below the hardware, briefly previews new attention events, and expands from the same visible hit region.
16. A local `mews@dev` Cask installs the app and CLI, runs without a Gatekeeper prompt, preserves explicit setup/undo, and uninstalls without leaving its artifacts.

Automated tests:

- Event validation.
- Primary-agent and subagent notification policy.
- Semantic attention reconciliation, replay suppression, session-scoped acknowledgement, and atomic state recovery.
- Physical-notch versus system-notification routing, including topology changes and batched events.
- Notification action routing, terminal metadata validation, and CLI-context path validation.
- Closed, peek, and expanded shell policy, compact status copy, notification-peek timing, deduplication, rendered-shell hit testing, and physical-notch occlusion geometry.
- Synthetic screenshot state coverage, privacy manifest checks, fixed pixel dimensions, and byte-identical repeat rendering.
- JSONL store append and rotation.
- IPC request parsing.
- Integration marker insertion and removal.
- Backup and restore behavior.
- Doctor checks for missing socket, denied notification permission, and unwritable store.
- Prerelease version parsing and isolated Homebrew Cask install/runtime/uninstall.

## Rollback

Every external write must have a rollback path:

| Write | Rollback |
|---|---|
| LaunchAgent plist | unload and delete plist |
| Claude Code settings | restore backup or remove Mews marker block |
| Codex hooks and trust state | remove only recorded Mews commands and trust markers; preserve user hooks and config |
| Copilot CLI hook | remove the Mews-owned hook file |
| Copilot hook correlation state | delete the Mews-owned opaque marker directory |
| Mews store | keep by default, delete with explicit reset command |

`mw undo` should not delete event history unless the user runs a separate reset command.

## Open Questions

1. Copilot CLI lifecycle compatibility needs real-session verification across supported versions, especially agents that omit explicit subagent lifecycle events.
2. Claude Code and Codex integrations need real-session compatibility checks as upstream payloads evolve.
These do not block the first architecture because each has a safe fallback.
