# AGENTS.md

This file provides guidance to AI coding agents when working in this repository.

## Project Overview

Mews is a local macOS companion for people who run AI coding agents in terminals. It provides:

- A `mw` CLI for setup, diagnostics, rollback, and scriptable agent events.
- A small macOS menu bar companion for current agent status and recent history.
- Local notifications for Claude Code, Codex, Copilot CLI, and long-running shell commands.
- A local-only, reversible setup flow built around `brew install mews`, `mw setup`, and `mw start`.

The product should feel like a Mole-style local Mac utility: simple command surface, boring safety, clear rollback, and no unnecessary dashboard.

## Current State

This repository has an init-preview Go CLI plus product and architecture docs. `README.md`, `docs/architecture.md`, and `docs/product-design.md` define the product direction. Do not assume planned menu bar behavior, tests, or release workflows are complete until the files and verification commands exist.

## Commands

Use existing commands only. If a command is not present yet, do not invent a successful validation result.

Planned contributor commands:

```bash
make build          # Build the mw CLI and package Mews.app
make test           # Run Go tests
make lint           # Run Go lint and shellcheck
make package        # Produce local release artifacts
make install-local  # Install into a local test prefix
make clean          # Remove build outputs
```

Planned user commands:

```bash
mw setup      # Show and apply supported local integrations
mw start      # Start the local agent after setup
mw status     # Print current watched tools and agent state
mw history    # Show recent local events
mw listen     # Listen in the terminal and print events as they arrive
mw doctor     # Diagnose permissions, integrations, LaunchAgent, and IPC
mw stop       # Stop the local agent
mw undo       # Remove Mews-installed integrations and restore backups
mw reset      # Delete local Mews data and logs

mw notify     # Advanced: send a custom event
mw run -- cmd # Advanced: run a command and report completion
```

## Architecture

Read `docs/architecture.md` before making architectural changes.

### Runtime pieces

1. **`mw` CLI**: installed by Homebrew, written primarily in Go.
2. **Mews Menu Bar Agent**: a thin macOS app bundle launched by `mw start`.
3. **Local IPC**: Unix domain socket under `~/Library/Application Support/Mews/`.
4. **Local Store**: JSON and JSONL files under `~/Library/Application Support/Mews/`.
5. **Integration Manager**: detects tools, installs safe local integrations, backs up changes, and supports `mw undo`.

### Planned source layout

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

Follow Go's `cmd/` + `internal/` convention. Keep most implementation private. Keep the root product-facing and easy to scan.

## Product Principles

- **Install, setup, start, undo**: the main path is `brew install mews`, `mw setup`, `mw start`, and `mw undo`.
- **Menu bar first**: users must see state even if they miss a notification.
- **Local-only**: no cloud service, account, telemetry, transcript upload, or terminal scrollback scraping in MVP.
- **No surprise writes**: explain integration changes, write backups, and support `mw undo`.
- **Fail honestly**: unsupported tools must show as unsupported or fallback, not silently broken.
- **Advanced paths stay advanced**: `mw notify`, wrappers, and hook details exist, but they should not lead the product.

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
- Prompt-derived task titles require explicit opt-in, must be truncated, and must stay local.
- Do not add network calls for core functionality.
- Do not add telemetry in MVP.
- Do not execute shell commands from received events.
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

The release process is not defined yet. Until it exists, do not invent tags, changelog entries, Homebrew formula updates, or release artifacts. When release automation is added, document it in `docs/architecture.md`, `README.md`, and this file in the same PR.
