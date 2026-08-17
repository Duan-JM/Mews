# Changelog

All notable changes to Mews will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

<!-- changelog release notes start -->

## [0.0.2] - 2026-08-17

### Changed

- Automated approved preflight releases and standardized Homebrew installation on the `mews` Cask. ([#95](https://github.com/Duan-JM/Mews/issues/95))

### Fixed

- Mews now hides an interrupted agent session when a newer session takes over the same terminal pane or window, while preserving sessions in other terminals. ([#97](https://github.com/Duan-JM/Mews/issues/97))


## [0.0.1] - 2026-08-14

### Added

- Added the `mw` CLI and macOS menu bar companion for local agent status, history, and notifications. ([#86](https://github.com/Duan-JM/Mews/pull/86))
- Added Claude Code, Codex, and Copilot CLI integrations with backups and reversible `mw undo`. ([#86](https://github.com/Duan-JM/Mews/pull/86))
- Added validated local IPC, event storage, terminal return actions, and runtime health diagnostics. ([#86](https://github.com/Duan-JM/Mews/pull/86))
- Added signed and notarized release packaging, checksum generation, and Homebrew Cask installation. ([#86](https://github.com/Duan-JM/Mews/pull/86))

### Security

- Kept core behavior local-only without accounts, telemetry, transcript upload, or terminal scrollback scraping. ([#86](https://github.com/Duan-JM/Mews/pull/86))
