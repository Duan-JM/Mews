# Contributing to Mews

Mews is an MVP release candidate. Keep changes small, local-first, reversible, and release-verifiable.

## Local setup

```bash
make lint-tools
make hooks
make check
make package
VERSION=dev ./scripts/smoke-package.sh
VERSION=v0.1.0-dev.1 make cask-smoke
```

`make lint-tools` installs the pinned Go, Swift, and Shell linters under `.tools/bin`.
`make check` runs lint, tests, and the build in sequence.

`make hooks` requires `pre-commit`; install it with `brew install pre-commit` if needed. The installed
pre-commit hook runs `make lint`, while the pre-push hook runs `make test`. Remove them without changing
tracked files:

```bash
pre-commit uninstall --hook-type pre-commit
pre-commit uninstall --hook-type pre-push
```

For an end-to-end local smoke:

```bash
./bin/mw setup
./bin/mw setup --yes
./bin/mw start
./bin/mw doctor
./bin/mw undo
```

## Branches and pull requests

`dev` is the integration branch, and `main` is the public stable branch.
Day-to-day changes start from the latest `dev`, use a scoped branch, and return
through a pull request targeting `dev`. Issue-backed branches should use
`<type>/<issue>-<short-kebab-slug>` and include `Refs #<issue>` in the pull
request body.

Use Conventional Commits for commit messages. Do not add AI tools as
co-authors. Do not push directly to `dev` or `main`.

The check, test, package, and CodeQL workflows run for pull requests targeting
`dev` or `main`. They also run on pushes to those two branches; pushing an issue
branch by itself does not start them. Wait for required checks before merging.

Copilot CLI automation uses one open, exclusively assigned issue, one linked
issue branch, and one dedicated worktree. Its detailed safety and rebase rules
live in `.github/instructions/github-workflow.instructions.md`.

## Changelog policy

Do not edit `CHANGELOG.md` in day-to-day pull requests. User-visible changes
must add one typed fragment under `changelog.d/`:

```text
<issue-or-pr>.added.md
<issue-or-pr>.changed.md
<issue-or-pr>.deprecated.md
<issue-or-pr>.removed.md
<issue-or-pr>.fixed.md
<issue-or-pr>.security.md
+short-slug.changed.md
```

Each fragment contains one concise, user-facing paragraph on one line.
Internal-only refactors, tests, and documentation corrections may omit a
fragment when the pull request explains why.

Validate fragments with `make changelog-check` and preview the next release
section with `make changelog-draft`. During an explicit release promotion,
consume all fragments and create the target version section:

```bash
make changelog-build VERSION=vX.Y.Z DATE=YYYY-MM-DD CONFIRM=yes
```

Review the generated `CHANGELOG.md`, confirm `changelog.d/` has no remaining
fragments, and run `VERSION=vX.Y.Z make release-check`. A release promotion
includes the generated changelog; day-to-day changes do not add version bumps,
tags, or release copy.

## Release and hotfix policy

A release promotion uses a pull request from `dev` to `main`. After that pull
request is merged, a maintainer runs the formal release command from a clean
`main` synchronized with `origin/main`. Publication is a second explicit,
confirmation-gated command:

An urgent hotfix starts from `main` and targets `main`. After it is merged, move
the same fix back to `dev` through a separate pull request. Do not use a direct
push for either direction.

Formal release validation requires macOS Developer ID and notarization credentials:

```bash
VERSION=vX.Y.Z \
SIGN_IDENTITY="Developer ID Application: ..." \
NOTARY_PROFILE=mews-notary \
make release

VERSION=vX.Y.Z CONFIRM=yes make publish-release
```

`make publish-release` verifies the source commit record, archive checksum,
Developer ID signatures, notarization ticket, Gatekeeper assessment, generated
Cask URL, and absence of the development quarantine bypass. It then creates or
resumes the tag and GitHub Release, downloads every public asset for bytewise
comparison, and publishes the Cask to the public `Duan-JM/homebrew-mews` tap. A
partial publication can be rerun when the existing tag still points to the
current `main`; mismatched tags fail closed.

Do not bypass these gates or publish an unsigned artifact as a formal release.

## Safety expectations

- Do not read prompts, transcripts, code snippets, or terminal scrollback by default.
- Do not add network calls or telemetry for core functionality.
- Before editing third-party config, write a Mews-owned file or create a backup.
- Every setup write must have a matching `mw undo` path.
- Destructive commands such as `mw reset --yes` must require explicit confirmation.

## Documentation

- Root `README.md` is the public front door.
- `docs/architecture.md` is the implementation design.
- `docs/product-design.md` is product framing, audience, MVP scope, state model, and risks.
- `SECURITY.md` and `SECURITY_AUDIT.md` track safety boundaries.

Do not document a command or integration as working until the implementation and verification command exist.
