# Security Audit Notes

Mews is still in project initialization. This document tracks the safety checks that must stay true as implementation starts.

## MVP Safety Checklist

- Event validation rejects unknown statuses and unsupported schema versions.
- `mews notify` accepts only metadata needed for local status display.
- `mews run -- <command>` records start and exit status without rewriting the command.
- `mews listen` prints event metadata only, not terminal scrollback or command output.
- Local state stays under `~/Library/Application Support/Mews/`.
- Logs stay under `~/Library/Logs/Mews/`.
- Integration edits create backups before writing.
- `mews undo` removes only Mews-owned integration blocks.
- Malformed third-party config files are not edited.
- Core functionality does not require network access.

## Current State

The repository contains the initial Go CLI, local JSONL event history, local Unix socket agent, foreground terminal listener, project documentation, and safety policy. The menu bar app and Homebrew formula are not implemented yet.
