# AGENTS.md

This file provides guidance to AI coding agents when working in this repository.

## Project Overview

Mews is a local macOS companion for people who run AI coding agents in terminals. It provides:

- A `mw` CLI for setup, diagnostics, rollback, and scriptable agent events.
- A small macOS menu bar companion for current agent status and recent history.
- Local notifications for Claude Code, Codex, Copilot CLI, and long-running shell commands.
- A local-only, reversible setup flow built around installing a verified package, `mw setup`, and `mw start`.

The product should feel like a Mole-style local Mac utility: simple command surface, boring safety, clear rollback, and no unnecessary dashboard.

## Current State

This repository has a release-candidate Go CLI, a thin Swift/AppKit menu bar app, safe Claude Code/Codex/Copilot CLI integrations, reversible setup state, and a credential-gated signed release pipeline. `README.md`, `docs/architecture.md`, and `docs/product-design.md` define the product direction.

## Commands

Use existing commands only. If a command is not present yet, do not invent a successful validation result.

Contributor commands:

```bash
make lint-tools     # Install pinned Go, Swift, and Shell linters under .tools/bin
make hooks          # Install pre-commit lint and pre-push test hooks
make check          # Run lint, tests, and the build
make build          # Build the mw CLI and package Mews.app
make test           # Run Go tests and Swift model tests
make lint           # Run Go, Swift, source-size, and shell lint checks
make screenshots    # Regenerate privacy-safe synthetic interface screenshots
make package        # Produce local release artifacts
make cask           # Produce a release archive and versioned Homebrew Cask
make cask-local     # Build a prerelease and prepare an ignored local Homebrew tap
make cask-smoke     # Exercise isolated Cask install, runtime, and uninstall
make release        # Sign, notarize, verify, and package a formal release
make install-local  # Install into a local test prefix
make clean          # Remove build outputs
```

User commands:

```bash
mw setup      # Show the supported integration plan
mw start      # Start the local agent after setup
mw status     # Print current watched tools and agent state
mw config terminal <name> # Select the terminal used for return actions
mw history    # Show recent local events
mw listen     # Listen in the terminal and print events as they arrive
mw doctor     # Diagnose permissions, integrations, LaunchAgent, and IPC
mw stop       # Stop the local agent
mw undo       # Remove Mews-installed integrations and restore backups
mw reset --yes # Delete local Mews data and logs after undo

mw notify     # Advanced: send a custom event
mw run -- cmd # Advanced: run a command and report completion
```

## Architecture

Read `docs/architecture.md` before making architectural changes.

### Runtime pieces

1. **`mw` CLI**: installed from a release package or Homebrew Cask, written primarily in Go.
2. **Mews Menu Bar Agent**: a thin macOS app bundle launched by `mw start`.
3. **Local IPC**: Unix domain socket under Application Support, with a private short-path fallback when macOS path limits require it.
4. **Local Store**: JSON and JSONL files under `~/Library/Application Support/Mews/`.
5. **Integration Manager**: resolves supported integration paths, installs safe local integrations, backs up changes, and supports `mw undo`.

### Source layout

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

Follow Go's `cmd/` + `internal/` convention. Keep most implementation private. Keep the root product-facing and easy to scan.

## Product Principles

- **Install, setup, start, undo**: the main path is installing a verified package, `mw setup`, `mw start`, and `mw undo`.
- **Menu bar first**: users must see state even if they miss a notification.
- **Local-only**: no cloud service, account, telemetry, transcript upload, or terminal scrollback scraping in MVP.
- **No surprise writes**: explain integration changes, write backups, and support `mw undo`.
- **Fail honestly**: unsupported tools must show as unsupported or fallback, not silently broken.
- **Advanced paths stay advanced**: `mw notify`, wrappers, and hook details exist, but they should not lead the product.

## Code Style

- Primary language: Go. The thin menu bar app uses Swift/AppKit.
- Use `gofmt` for all Go code.
- Keep `.golangci.yml` and `.swiftlint.yml` strict for complexity, function size, parameter shape, line length, and file size.
- Split code by responsibility instead of adding broad lint suppressions.
- Keep package names short, lowercase, and specific.
- Prefer small interfaces at package boundaries.
- Keep CLI output human-readable and stable enough for docs.
- Avoid broad catch-all logic that hides integration failures.
- Comments should be in English and explain non-obvious behavior only.

## Safety and Privacy

Mews edits local tool configuration and runs as a menu bar companion, so safety boundaries are product requirements.

- Do not read prompts, transcripts, code snippets, or terminal scrollback by default.
- Prompt-derived task titles require explicit opt-in, must be truncated, and must stay local.
- Do not add network calls for core functionality.
- Do not add telemetry in MVP.
- Do not execute shell commands from received events.
- Terminal return actions may use only validated identifiers, validated absolute directories, same-user local sockets, and fixed kitty or tmux argument lists.
- Do not write outside Mews-owned paths or known integration files.
- Before editing third-party config, create a backup and record it in the integration state.
- `mw undo` must remove Mews-owned integration blocks without deleting unrelated user config.
- If a config file is malformed, refuse to edit it and surface the issue through `mw doctor`.

## Testing

Tests should cover:

- Event validation.
- JSON and JSONL store behavior.
- Unix socket request parsing.
- Integration marker insertion and removal.
- Backup and restore behavior.
- Doctor checks for missing socket, notification denial, missing LaunchAgent, and unwritable store.
- `mw run -- <command>` exit status mapping.

External tools and macOS integration points should be mocked where practical. Do not require Claude Code, Codex, or Copilot CLI to be installed for unit tests.

## Documentation

Update docs with the code change that makes them true.

- `README.md`: user-facing product promise, install path, commands, privacy, and roadmap.
- `docs/architecture.md`: runtime design, integration strategy, storage, IPC, packaging, and rollback.
- `docs/product-design.md`: product framing, audience, MVP scope, state model, and risks.
- `AGENTS.md`: agent workflow, repository structure, commands, and safety rules.

Do not document commands as working until they exist.

## AI Engineering Workflow

Use this workflow for changes large enough to touch multiple product surfaces:

1. **Define the outcome contract first**: name the user-visible result, safety invariants, rollback path, and commands that prove completion.
2. **Read before editing**: inspect the current implementation, tests, docs, worktree state, and remote state. Current code and runtime evidence override plans and memory.
3. **Track dependency-aware work**: split the task into implementation, tests, distribution, and documentation. Start only work whose dependencies are satisfied.
4. **Parallelize by file ownership**: delegate independent areas such as release scripts and application logic, but never let two agents edit the same files or investigate the same scope.
5. **Instrument uncertain behavior**: reproduce runtime assumptions with a focused probe before writing compensating code. Compilation alone is not enough for menu bar, notification, IPC, package, or install behavior.
6. **Implement the safety path with the feature**: every config write needs validation, backup evidence, exact ownership markers, and an undo test. Failure must leave user configuration unchanged.
7. **Verify in layers**: run targeted unit tests, then lint, build, package checksum verification, isolated install smoke, and a real app/IPC smoke when native behavior changes.
8. **Synchronize documentation last**: update public promises only after the implementation and verification commands exist. Remove stale “planned” statements in the same change.
9. **Publish without collapsing states**: report source, CI, package, signing/notarization, and GitHub PR/release state separately. Do not call an unsigned local archive a release.

Keep agent notes concise and reusable. Do not copy private transcripts, local machine paths, credentials, issue-specific incidents, or temporary debugging output into tracked guidance.

## Branch and PR Workflow

Use `dev` as the integration branch. `main` is the public stable branch.
`.github/instructions/github-workflow.instructions.md` is the canonical
automation workflow, and `CONTRIBUTING.md` defines the contributor-facing
branch, pull request, changelog, and release policy.

For day-to-day agent work:

1. Create or claim one open issue and keep it assigned exclusively to the authenticated account.
2. Use the issue's single linked branch and a dedicated worktree under `.worktree/`.
3. Branch from the latest `dev` with a Conventional Commits type and an issue-scoped kebab-case name.
4. Implement only the claimed issue, audit related documentation, and run the required verification.
5. Commit with Conventional Commits format. Do not add AI tools as co-authors.
6. Push the issue branch and open a pull request against `dev` with `Refs #<issue>`.
7. Wait for required CI before merging. Merge and issue closure require an explicit request in the current turn.

### Direct push rules

- Do not push directly to `main`.
- Do not push directly to `dev`.
- Do not target `main`, merge, close issues, or delete branches and worktrees without explicit current-turn authorization.
- After an authorized safe rebase, use only `--force-with-lease` when a rewritten issue branch must be updated.

## Release Workflow

Release promotions and urgent hotfix pull requests targeting `main` require an
explicit current-turn request and must follow `CONTRIBUTING.md`.

Formal releases run only on macOS and require:

```bash
VERSION=vX.Y.Z \
SIGN_IDENTITY="Developer ID Application: ..." \
NOTARY_PROFILE=mews-notary \
make release
```

The command builds with the requested version, signs the CLI and app with hardened runtime, notarizes and staples the app, verifies it with Gatekeeper, and produces a tarball, SHA-256 checksum, and checksum-pinned Homebrew Cask. Missing credentials or an invalid version must fail. Do not create tags, GitHub releases, or publish the Cask to a tap unless the human explicitly requests that publication action.
