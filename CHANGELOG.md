# Changelog

All notable changes to Mews will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

<!-- changelog release notes start -->

## [0.0.3] - 2026-09-07

### Added

- Stopped Active Sessions can now be hidden with an Apple Mail-style left swipe while local history and the underlying CLI session remain intact. ([#113](https://github.com/Duan-JM/Mews/issues/113))

### Changed

- Open confirmed Codex App sessions directly from Mews while preserving exact tmux and terminal return behavior. ([#107](https://github.com/Duan-JM/Mews/issues/107))
- Active Sessions use a calmer dark-red HIDE button, with better vertical spacing for status and row controls. ([#122](https://github.com/Duan-JM/Mews/issues/122))

### Fixed

- Detect Codex App sessions from the environment exposed by current desktop builds. ([#109](https://github.com/Duan-JM/Mews/issues/109))
- Detect Codex App sessions when current Codex hooks omit App-specific environment variables, so Return can open the matching thread instead of falling back to the terminal. ([#111](https://github.com/Duan-JM/Mews/issues/111))
- HIDE now grows from a circle into a matching row button, then lengthens leftward from a fixed right edge. Past the 20% threshold, the red button springs across the row while only its text snaps to the leading inset. The subtly darker background follows native macOS material and accessibility settings, and settling, retry, and removal animate correctly inside the native session list. ([#124](https://github.com/Duan-JM/Mews/issues/124))
- Fix active-session selection after partial event-log recovery so an older session cannot hide a newer session when the full log becomes available, including after restart. ([#129](https://github.com/Duan-JM/Mews/issues/129))


## [0.0.2] - 2026-08-17

### Changed

- Automated approved preflight releases and standardized Homebrew installation on the `mews` Cask. ([#95](https://github.com/Duan-JM/Mews/issues/95))

### Fixed

- Mews now hides an interrupted agent session when a newer session takes over the same terminal pane or window, while preserving sessions in other terminals. ([#97](https://github.com/Duan-JM/Mews/issues/97))
- Fixed automated release publication when GitHub Actions uses an installation token. ([#104](https://github.com/Duan-JM/Mews/issues/104))


## [0.0.1] - 2026-08-14

### Added

- Added the `mw` CLI and macOS menu bar companion for local agent status, history, and notifications. ([#86](https://github.com/Duan-JM/Mews/pull/86))
- Added Claude Code, Codex, and Copilot CLI integrations with backups and reversible `mw undo`. ([#86](https://github.com/Duan-JM/Mews/pull/86))
- Added validated local IPC, event storage, terminal return actions, and runtime health diagnostics. ([#86](https://github.com/Duan-JM/Mews/pull/86))
- Added signed and notarized release packaging, checksum generation, and Homebrew Cask installation. ([#86](https://github.com/Duan-JM/Mews/pull/86))

### Security

- Kept core behavior local-only without accounts, telemetry, transcript upload, or terminal scrollback scraping. ([#86](https://github.com/Duan-JM/Mews/pull/86))
