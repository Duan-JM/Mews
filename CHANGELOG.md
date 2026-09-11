# Changelog

All notable changes to Mews will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

<!-- changelog release notes start -->

## [0.0.4] - 2026-09-10

### Changed

- Keep a seven-point gutter and concentric trailing corners between session row actions and the swipe-to-hide reveal. ([#142](https://github.com/Duan-JM/Mews/issues/142))

### Fixed

- Replace the persistent physical-notch status strip with quiet aggregate red and green edge glows while preserving the existing expanded panel. ([#132](https://github.com/Duan-JM/Mews/issues/132))
- Keep the notch glow tight to the hardware edge and carry its color and pulse onto the expanded panel. ([#136](https://github.com/Duan-JM/Mews/issues/136))
- Align the collapsed notch outline with the measured hardware contour, keep its visible edge thickness uniform, and let the soft glow fade below the menu bar without clipping the bottom edge or changing expanded-panel effects. ([#138](https://github.com/Duan-JM/Mews/issues/138))
- Unify the collapsed notch signal with a continuous black backing instead of guessing hardware corner geometry. Keep the expanded notch glow on its left, right, and bottom edges, synchronize the backing and glow through one shared animation clock throughout expansion and collapse, and preserve soft glow outside the content window without intercepting clicks. ([#140](https://github.com/Duan-JM/Mews/issues/140))
- Vertically center the expanded session row actions and keep the swipe-revealed HIDE control aligned throughout its transition. ([#141](https://github.com/Duan-JM/Mews/issues/141))
- Limit the expanded shell's colored outline, glow, breathing edge, and stop pulse to physical-notch displays while preserving the top-center panel and notification fallback. ([#143](https://github.com/Duan-JM/Mews/issues/143))
- Improved physical-notch expand and collapse smoothness while keeping the black backing aligned and correctly oriented around the hardware notch. ([#147](https://github.com/Duan-JM/Mews/issues/147))
- Keep local Homebrew Cask setup and release smoke checks compatible with Homebrew's tap trust requirements.


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
