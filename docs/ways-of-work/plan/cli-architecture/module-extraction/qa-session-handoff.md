# Separate-session CLI extraction QA handoff

Use this document to start the independent QA session after implementation.
It is a planned handoff, not evidence that the extraction exists or works.

## Context to load

Read repository instructions and these artifacts before running tests:

1. [Specification](../../../../specs/cli-module-extraction.md).
2. [Implementation plan](implementation-plan.md) and full Beads epic/children.
3. [Test strategy](test-strategy.md), [checklist](test-issues-checklist.md), and
   [QA gates](qa-plan.md).
4. The implementation session's exact-revision handoff and migrated tests.
5. Existing [CLI contract](../../../../agent-cli.md),
   [annotation evidence](../../../../agent-annotation-verification.md), and
   [capture evidence](../../../../agent-cli-verification.md) as historical
   references, not extraction results.

Use `BEADS_DIR=/Users/dartsiukhou/dev/personal/vishot/.beads` explicitly in a
sibling worktree and verify it with `bd where`. Locate the QA ticket through
`vishot-1us.6` under epic `vishot-1us`, using the `cli-module-extraction` spec
link and parent/child graph. Don't assume the
original annotation branch is still the correct execution checkout.

## First actions

Confirm the following before acceptance execution:

- Identify repository, branch, revision, dirty files, and installed/built app.
- Check Gate 1 and read all actual blockers; don't test a partial candidate as
  if it were the finished extraction.
- Inventory tests with current SwiftPM targets; renamed/moved suites must still
  be discovered. Keep commands consistent with actual package structure.
- Use isolated homes/workspaces and public fixtures. Retain exact output paths.
- Obtain explicit authorization before replacing/relaunching the installed app
  or changing permission state. Existing approval for earlier annotation smoke
  checks isn't a blanket authorization for new installation actions.

## Command starting points

These existing commands guide the future session; adapt test filters and bundle
paths to the completed extraction rather than copying stale private routing:

```sh
git status --short
git rev-parse HEAD
swift test --force-resolved-versions
swift test --force-resolved-versions --enable-code-coverage
npm test --prefix site
./scripts/build.sh
codesign --verify --deep --strict build/Vishot.app
build/Vishot.app/Contents/Helpers/vishot --version
git diff --check
```

Run coverage separately only when needed to obtain metrics; avoid repeating an
unchanged full suite without a reason. Packaging checks follow the repository's
existing hash-locked setup if packaging inputs changed. Don't install new tools
or fetch dependencies merely to satisfy generic skill examples.

## Required output

Write a redacted QA report with tested revision, environment, commands, scenario
outcomes, fixture hashes/dimensions, actual image observations, and defect links.
Keep raw screenshots outside public tracked artifacts unless they are intended
public fixtures. Record opening accepted versus visible, and every blocked
platform/manual cell. Update the QA ticket without committing, pushing, merging,
publishing, or changing the PR unless separately authorized.
