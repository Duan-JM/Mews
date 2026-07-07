# AGENTS.md

This file provides guidance to AI coding agents when working in this repository.

## Project Overview

Mews is a local macOS companion for people who run AI coding agents in terminals. It provides:

- A `mews` CLI for setup, diagnostics, rollback, and scriptable agent events.
- A small macOS menu bar companion for current agent status and recent history.
- Local notifications for Claude Code, Codex, Copilot CLI, tmux, and long-running shell commands.
- A local-only, reversible setup flow built around `brew install mews` and `mews start`.

The product should feel like a Mole-style local Mac utility: simple command surface, boring safety, clear rollback, and no unnecessary dashboard.

## Current State

This repository has an initial Go CLI skeleton plus product and architecture docs. `README.md`, `architecture.md`, and `pre-app-store-product-design.md` define the product direction. Do not assume planned commands, menu bar behavior, tests, or release workflows are complete until the files and verification commands exist.

## Commands

Use existing commands only. If a command is not present yet, do not invent a successful validation result.

Planned contributor commands:

```bash
make build          # Build the mews CLI and package Mews.app
make test           # Run Go tests
make lint           # Run Go lint and shellcheck
make package        # Produce local release artifacts
make install-local  # Install into a local test prefix
make clean          # Remove build outputs
```

Planned user commands:

```bash
mews start      # Start Mews and enable supported tools
mews status     # Print current watched tools and agent state
mews history    # Show recent local events
mews listen     # Listen in the terminal and print events as they arrive
mews doctor     # Diagnose permissions, integrations, LaunchAgent, and IPC
mews stop       # Stop the local agent
mews undo       # Remove Mews-installed integrations and restore backups

mews notify     # Advanced: send a custom event
mews run -- cmd # Advanced: run a command and report completion
```

## Architecture

Read `architecture.md` before making architectural changes.

### Runtime pieces

1. **`mews` CLI**: installed by Homebrew, written primarily in Go.
2. **Mews Menu Bar Agent**: a thin macOS app bundle launched by `mews start`.
3. **Local IPC**: Unix domain socket under `~/Library/Application Support/Mews/`.
4. **Local Store**: JSON and JSONL files under `~/Library/Application Support/Mews/`.
5. **Integration Manager**: detects tools, installs safe local integrations, backs up changes, and supports `mews undo`.

### Planned source layout

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

Follow Go's `cmd/` + `internal/` convention. Keep most implementation private. Keep the root product-facing and easy to scan.

## Product Principles

- **Install, start, done**: the main path is `brew install mews` and `mews start`.
- **Menu bar first**: users must see state even if they miss a notification.
- **Local-only**: no cloud service, account, telemetry, transcript upload, or terminal scrollback scraping in MVP.
- **No surprise writes**: explain integration changes, write backups, and support `mews undo`.
- **Fail honestly**: unsupported tools must show as unsupported or fallback, not silently broken.
- **Advanced paths stay advanced**: `mews notify`, wrappers, and hook details exist, but they should not lead the product.

## Code Style

- Primary language: Go.
- Use `gofmt` for all Go code.
- Keep package names short, lowercase, and specific.
- Prefer small interfaces at package boundaries.
- Keep CLI output human-readable and stable enough for docs.
- Avoid broad catch-all logic that hides integration failures.
- Comments should be in English and explain non-obvious behavior only.

## Safety and Privacy

Mews edits local tool configuration and runs as a menu bar companion, so safety boundaries are product requirements.

- Do not read prompts, transcripts, code snippets, or terminal scrollback by default.
- Do not add network calls for core functionality.
- Do not add telemetry in MVP.
- Do not execute shell commands from received events.
- Do not write outside Mews-owned paths or known integration files.
- Before editing third-party config, create a backup and record it in the integration state.
- `mews undo` must remove Mews-owned integration blocks without deleting unrelated user config.
- If a config file is malformed, refuse to edit it and surface the issue through `mews doctor`.

## Testing

Tests should cover:

- Event validation.
- JSON and JSONL store behavior.
- Unix socket request parsing.
- Integration marker insertion and removal.
- Backup and restore behavior.
- Doctor checks for missing socket, notification denial, missing LaunchAgent, and unwritable store.
- `mews run -- <command>` exit status mapping.

External tools and macOS integration points should be mocked where practical. Do not require Claude Code, Codex, Copilot CLI, or tmux to be installed for unit tests.

## Documentation

Update docs with the code change that makes them true.

- `README.md`: user-facing product promise, install path, commands, privacy, and roadmap.
- `architecture.md`: runtime design, integration strategy, storage, IPC, packaging, and rollback.
- `pre-app-store-product-design.md`: product framing before any paid Mac app.
- `AGENTS.md`: agent workflow, repository structure, commands, and safety rules.

Do not document commands as working until they exist.

## Branch and PR Workflow

Use `dev` as the integration branch. `main` is the public stable branch.

### Branch flow

1. Branch from latest `dev`.

   ```bash
   git checkout dev
   git pull --ff-only origin dev
   git checkout -b <type>/<slug>
   ```

   `<type>` should match Conventional Commits: `feat`, `fix`, `docs`, `refactor`, `test`, or `chore`. Use 2-5 word kebab-case slugs.

2. Implement and verify locally with the smallest available command set. If no test or lint command exists yet, say that clearly in the PR verification section.

3. Commit with Conventional Commits format. Every commit message must include:

   ```text
   Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>
   ```

4. Push the branch and open a PR against `dev`.

   ```bash
   git push -u origin HEAD
   gh pr create --fill --base dev
   ```

5. Watch CI and fix until green. If CI is still red after three fix attempts, stop and summarize what failed.

6. Do not auto-merge. Report the PR URL and final CI state. Human review decides when to merge.

### Direct push rules

- Do not push directly to `main`.
- Do not push directly to `dev` unless the human explicitly asks for branch setup or repository bootstrap.
- Do not rewrite remote history unless the human explicitly asks.

## Release Notes

The release process is not defined yet. Until it exists, do not invent tags, changelog entries, Homebrew formula updates, or release artifacts. When release automation is added, document it in `architecture.md`, `README.md`, and this file in the same PR.
