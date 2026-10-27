# Landing-page CLI QA handoff

The landing page distinguishes released discovery/capture from the unreleased
annotation preview. W1 and W2 below are prepared for independent QA; no site
tests, browser checks, CLI commands, or installation were executed in this
implementation sessions. The integrated review-fix session permits only source
review, content identity computation, `git diff --check`, and compile-only
`swift build --force-resolved-versions --build-tests`. Test assertions and runtime
acceptance remain unexecuted.

Publication update: the identity below is the historical pre-commit snapshot.
The branch subsequently fast-forwarded to `dd0cd35` to preserve the remote
release synchronization before committing these changes. Pin the published
extraction commit and any current dirty diff for QA. A user-approved signed
installation and private annotation walkthrough followed implementation; site
tests and browser checks remain pending.

## Candidate

The final integration checkout is
`/Users/dartsiukhou/dev/personal/vishot-agent-annotations`, branch
`integration/agent-annotations`. Its base and exact HEAD are both
`bcae50da04b0ed75aae1f6fe720b51f90b697b20`. The candidate includes the uncommitted
shared modules, CLI, app integration, site, documentation, planning, and review
fixes together. The base alone is not the candidate.

Final identity computation output:

```text
HEAD=bcae50da04b0ed75aae1f6fe720b51f90b697b20
CHANGED_PATHS=96
MANIFEST_GIT_BLOB=d79f69046687710e3fffe8ae083579002a331fe6
MANIFEST_SHA256=850b39e25caaaba62b410ccd2ba40e8b90b5b5871738fc23352bb1711b5a657d
```

Run `python3 -B scripts/candidate-identity.py` from that checkout to reproduce
the canonical manifest and output. The
[implementation handoff](ways-of-work/plan/cli-architecture/module-extraction/implementation-handoff.md#reproduce-the-content-identity)
documents the exact Git commands, status/path/mode/blob records, HEAD, and JSON
serialization. It covers tracked modifications and deletions and all intended
nonignored untracked source, tests, docs, and plans. Private `.vishot` data is
excluded entirely before hashing. This file is a QA procedure and identity
carrier; it and the implementation handoff are explicitly excluded to avoid
self-reference. Their bytes are not part of the content identity.

Review fixed duplicate selectable treatment mapping by deriving shipping GUI
definitions from shared `VisualStyle.annotationID`, preserving saved IDs and
custom GUI definitions. An app/shared rendered-output assertion is prepared and
compiled, not executed. Both handoffs now identify this integrated candidate.
The parent owns ticket closure; independent QA records runtime outcomes later.

## Public release evidence

Read-only GitHub retrieval on October 27, 2026 established the following:

- `gh release list --repo dartyuhov/vishot --limit 10` listed `v0.2.0` as latest
  and `v0.1.0` as the earlier release.
- `gh release view --repo dartyuhov/vishot --json
  tagName,targetCommitish,publishedAt,isDraft,isPrerelease,url,assets,body`
  returned [v0.2.0](https://github.com/dartyuhov/vishot/releases/tag/v0.2.0),
  published at `2026-10-27T12:15:51Z`, with draft and prerelease both false.
  Both native DMGs and their checksum/provenance sidecars were uploaded.
  Retrieval completed at `2026-10-27T15:05:35Z`.
- `gh api repos/dartyuhov/vishot/git/ref/tags/v0.2.0` resolved the lightweight
  tag directly to commit `4f843572a51a3d1eb76c4a441713d5811b10e98a`, matching
  the release target and release-body source marker.
- `gh api` with `Accept: application/vnd.github.raw+json` read
  `contents/docs/agent-cli.md?ref=v0.2.0`,
  `contents/Sources/VishotCLI/main.swift?ref=v0.2.0`,
  `contents/scripts/build.sh?ref=v0.2.0`, and
  `contents/skills/vishot-capture/SKILL.md?ref=v0.2.0`.
  These establish bundled `Contents/Helpers/vishot`, discovery, exact-ID capture,
  immediate image reading, and optional skill instructions. The actual tagged
  command parser permits only `windows`, `capture`, and `--version`; it rejects
  `annotate`. The published release does not include annotation or `--open`.
  Tagged source retrieval occurred between `15:05:35Z` and `15:06:36Z`.
- Repository metadata reported public visibility and default branch `main`;
  `commits/main` returned the same release commit. Neither local installation nor
  newer source was used as evidence of released capability.
- Raw retrieval of `docs/agent-cli.md` at
  `bcae50da04b0ed75aae1f6fe720b51f90b697b20` completed by
  `2026-10-27T15:06:36Z`. Its public annotation workflow heading, JSON schema,
  commands, and result contract support the explicitly unreleased reference
  link. This older source still describes process replacement; the landing page
  makes no claim about the extraction's unpublished internal architecture.

This is release metadata and tagged-source evidence, not downloaded-installer
or runtime verification. Recheck public releases before changing availability
copy. Retain the preview label until a published tag actually includes it.

## W1: served content, links, and installation gates

Run the site suite later with the pinned Node version, then record results and
the tested candidate. The prepared `site/server.test.js` assertion replaces the
obsolete CLI planned-only expectation and parses the inline mixed-mark JSON.

1. Run `npm test --prefix site`. Verify served content includes the bundled
   discovery/capture commands, exact live ID selection, immediate built-in image
   reading, same-input annotation, pixel geometry, local retention, unchanged
   original/dimensions, save-only default, and optional `--open` semantics.
2. Verify both the always-visible CLI card and expanded FAQ distinguish v0.2.0
   capture from unreleased annotation. The annotation example must not imply it
   works with the released installer. Its path, ID, and geometry are examples;
   agents must substitute discovery results and inspected image coordinates.
3. Follow the release, tagged capture docs, tagged optional capture skill, and
   commit-pinned unreleased annotation reference links. Confirm the latter
   reaches the explanation heading and the released skill needs no annotation
   support. This page offers skill instructions, not an installer execution.
4. Verify the existing metadata suite still fails closed with installation
   disabled, incomplete/private metadata, or a mismatched cask; only complete
   verified release/tap fixtures plus the explicit enable flag reveal controls.
   The informational CLI card must not enable downloads or Homebrew by itself.
5. Confirm retired signup/export routes, allowlisted assets, local navigation,
   and the existing history-preview expectations still pass.

## W2: responsive, keyboard, demo, and motion checks

Use the available browser in the later QA session and record browser, viewport,
zoom, motion preference, JavaScript state, and observed outcomes.

1. At 375 × 812, 768 × 1024, 1024 × 640, and 1440 × 900, inspect the CLI card
   and expanded FAQ. Repeat at 200% zoom. Bundled paths and JSON must wrap without
   page-wide horizontal overflow; all content must remain reachable through
   scrolling, including the long FAQ in the desktop snap layout.
2. Follow the card's workflow anchor, then Tab to the native FAQ summary and
   toggle it with Enter/Space. Check visible focus, meaningful link text, and
   keyboard access to each documentation link. Confirm card links are not
   covered by the demo cards' stretched-button hit area.
3. Exercise all six existing demo buttons and pause/resume. The CLI card must
   remain readable as the active demo changes, without creating a seventh demo
   segment or changing existing keycasts, canvas content, or video behavior.
4. Repeat with reduced motion enabled and with JavaScript disabled. Check CLI
   content, FAQ expansion, documentation links, and install status remain usable;
   preserve existing reduced-motion and video opt-in behavior.
5. Check download chooser keyboard dismissal and focus return using the existing
   ready-metadata setup, and the disabled-install state separately. Record any
   unavailable fixture/browser checks as blocked rather than passed.

Keep W1/W2 execution outcomes in the independent QA report and shared Beads
ticket `vishot-1us.6`, using
`BEADS_DIR=/Users/dartsiukhou/dev/personal/vishot/.beads`.
