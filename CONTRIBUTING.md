# Contributing to Mews

Mews is in init preview. Keep changes small, local-first, and reversible.

## Local setup

```bash
make build
make test
make lint
```

For an end-to-end local smoke:

```bash
./bin/mw setup
./bin/mw setup --yes
./bin/mw doctor
./bin/mw undo
```

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
