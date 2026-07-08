# Security Policy

Mews is a local macOS utility. Its core job is to connect local AI coding tools to local notifications without uploading prompts, transcripts, code, or terminal output.

## Supported Versions

Mews has not shipped a stable release yet. Security reports should target the current `main` or `dev` branch until a release policy exists.

## Reporting a Vulnerability

Please open a private security advisory on GitHub if the issue involves:

- Reading prompts, transcripts, code snippets, or terminal scrollback unexpectedly.
- Writing outside Mews-owned paths or known integration files.
- Unsafe integration edits that cannot be reversed.
- Executing shell commands from untrusted event input.
- Leaking local paths, project names, or event history outside the machine.

Do not include private prompts, code, or transcripts in public issues.

## Security Boundaries

- No network calls for core functionality.
- No telemetry in MVP.
- No terminal scrollback scraping by default.
- No execution of shell commands from received events.
- Integration edits must be backed up and reversible through `mw undo`.

