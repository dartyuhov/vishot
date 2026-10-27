# CLI extraction quality assurance plan

This plan defines independent gates for the approved extraction. The user
requested test execution in a separate session. No gate is passed merely by
writing these documents or by reusing pre-extraction results.

## Gate 1: ready for independent QA

The implementation handoff must provide a reproducible candidate:

- First four approved slices are completed with a migrated-test inventory.
- The added landing-page CLI explanation is ready for served-page/browser QA.
- Exact source revision, uncommitted changes, build instructions, and known
  defects are identified.
- Shared module dependency direction, resource ownership, and removed routing
  are documented for review.
- Fixture data and baseline are available; missing baseline evidence is marked.
- Required native host/signing resources are identified. Missing optional hosts
  block those coverage cells, not every available local check.

## Gate 2: automated and structural validation

The separate QA session evaluates the candidate's interfaces and behavior:

- All applicable locked Swift tests pass, with discovered counts recorded.
- Architecture scenarios A1–A2 pass: annotation doesn't execute the GUI binary,
  and shared modules have no reverse dependency on GUI lifecycle.
- Contract, geometry, DPI, configuration, publication, and opening cases pass.
- Existing capture isolation/deadline, history, and live Settings checks pass.
- Every removed test has equivalent surviving behavior coverage or rationale.
- Coverage targets from the strategy are measured where supported; unavailable
  metrics are recorded instead of fabricated.

## Gate 3: signed integration and visual validation

Runtime observations complement automated checks:

- Build with the stable identity and verify nested signatures and resources.
- Use the real helper and bundled fonts for both styles at 1x/2x.
- Capture a public fixture, actually read it, annotate that same PNG, and read
  the flattened output. Confirm dimensions and original hashes.
- Observe clipboard/history integrity and no watermark/local-PNG permission UI.
- Exercise explicit default-app opening. Record OS acceptance separately from
  actual document display; retain the result on opening failure.
- Complete available editor/Settings and capture responsiveness checks.
- Run the site suite and focused CLI-content, link, responsive, keyboard, demo,
  and release-availability browser checks.
- Record Intel/macOS 14, denied TCC, and native cross-Space gaps honestly.

User installation/relaunch, permission changes, or personal-window inspection
require explicit permission in that session. Prefer an isolated signed bundle
and non-private fixtures. Never switch stable signing to ad-hoc for installed
permission checks.

## Gate 4: disposition and handoff

The QA report must make unresolved risk visible:

- Map all acceptance criteria and high-risk scenarios to pass/fail/blocked.
- Require zero unresolved critical/high defects. Don't waive failed tests with
  a percentage pass rate.
- Investigate repeatable performance increases above the strategy's trigger.
- Record exact commands, outputs, platform, fixture identity, and source hash.
- Keep blocked host/manual checks open or explicitly accepted by the user;
  never turn an unavailable check into a pass.
- Link actual defects and rerun evidence in Beads. Don't close earlier capture
  or annotation verification tickets merely because extraction checks pass.

## Escalation

Stop acceptance on a contract change, precision loss, signature/resource defect,
capture isolation regression, or unexpected data modification. Supply a minimal
reproduction and affected scenario IDs to the implementation session. Re-test
the fix and directly affected regressions before recommending acceptance.

Use the repository's `ready-for-agent`/`ready-for-human`/`needs-info` vocabulary
when a real blocker needs triage. No automatic release, merge, push, or PR
mutation is part of QA completion.
