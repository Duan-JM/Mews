# Security Audit Notes

This document tracks the safety checks that must stay true for the release MVP.

## MVP Safety Checklist

- Event validation rejects unknown statuses and unsupported schema versions.
- `mw notify` accepts only metadata needed for local status display.
- `mw run -- <command>` records start and exit status without rewriting the command.
- `mw listen` prints event metadata only, not terminal scrollback or command output.
- Local state stays under `~/Library/Application Support/Mews/`.
- Logs stay under `~/Library/Logs/Mews/`.
- Integration edits create backups before writing.
- `mw undo` removes only Mews-owned integration blocks.
- Malformed third-party config files are not edited.
- Existing Codex `notify` commands are not replaced.
- Event metadata has field-size limits and the JSONL history is bounded.
- Terminal return actions validate directories and terminal identifiers, restrict tmux sockets to the current user, and use fixed kitty and tmux argument lists.
- Formal release packaging fails when signing or notarization credentials are missing.
- Core functionality does not require network access.

## Current State

The release MVP includes the Go CLI, bounded JSONL history, Unix socket agent, LaunchAgent-managed Swift/AppKit menu bar app, native notification permission reporting, safe integrations for Claude Code, Codex, and Copilot CLI, and validated return actions for attached and detached tmux contexts.

Setup writes backups and an `integrations.json` audit record before editing existing configuration. Undo removes exact Claude commands, the marked Codex block, and the Mews-owned Copilot hook while preserving unrelated edits made after setup.

CI covers tests, lint, CodeQL, universal macOS build, package checksum verification, and isolated package and Homebrew Cask runtime smokes. Formal release remains a maintainer action because Developer ID and notarization credentials are required. The generated Cask installs the signed app and links its bundled CLI; the tap has not been published yet. The ignored local development Cask removes quarantine only for an ad-hoc signed build and is never a release artifact.
