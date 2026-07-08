# Security Audit Notes

Mews is still in project initialization. This document tracks the safety checks that must stay true as implementation starts.

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
- Core functionality does not require network access.

## Current State

The repository contains an init-preview Go CLI, local JSONL event history, local Unix socket agent, foreground terminal listener, project documentation, and safety policy. Copilot CLI user-level hook installation is implemented with Mews-owned files and `mw undo` removal. The menu bar app, Homebrew formula, LaunchAgent, Claude Code integration, and Codex integration are not implemented yet.
