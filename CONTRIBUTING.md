# Contributing to Mews

Mews is an MVP release candidate. Keep changes small, local-first, reversible, and release-verifiable.

## Local setup

```bash
make lint-tools
make build
make test
make lint
make package
VERSION=dev ./scripts/smoke-package.sh
```

`make lint-tools` installs the pinned Go, Swift, and Shell linters under `.tools/bin`.

For an end-to-end local smoke:

```bash
./bin/mw setup
./bin/mw setup --yes
./bin/mw doctor
./bin/mw undo
```

Formal release validation requires macOS Developer ID and notarization credentials:

```bash
VERSION=vX.Y.Z \
SIGN_IDENTITY="Developer ID Application: ..." \
NOTARY_PROFILE=mews-notary \
make release
```

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
