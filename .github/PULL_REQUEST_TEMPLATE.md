## Summary

Describe the user-visible result and why the change is needed.

## Verification

List the exact commands and outcomes.

## Checklist

- [ ] This PR targets `dev`, unless it is an explicitly authorized release or hotfix PR.
- [ ] User-visible changes add `changelog.d/<issue-or-pr>.<type>.md`, or the summary explains why no fragment is needed.
- [ ] Related contributor, architecture, command, and user documentation is updated.
- [ ] No AI tool is listed as a commit co-author.

## Release checklist (`dev` to `main` only)

- [ ] Fragments were consumed with `make changelog-build VERSION=vX.Y.Z DATE=YYYY-MM-DD CONFIRM=yes`.
- [ ] `CHANGELOG.md` contains the target version and release date, and `changelog.d/` has no unconsumed fragments.
- [ ] `VERSION=vX.Y.Z make release-check` passed.
- [ ] Required pull request CI passed.
