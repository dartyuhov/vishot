# CLI extraction test issues checklist

These are execution subtasks of the final approved Beads QA ticket, not additional
published tickets. All boxes start unchecked because this is planning only.
Scenario definitions are in the [test strategy](test-strategy.md).

## Preparation and traceability

The QA session prepares evidence before execution:

- [ ] Pin implementation revision, dirty diff identity, and baseline `bcae50d`.
- [ ] Read the spec, full tickets, migrated-test inventory, and known gaps.
- [ ] Verify acyclic blockers and all implementation prerequisites.
- [ ] Prepare non-private fixtures, isolated homes, and signed bundle location.
- [ ] Record native OS/architecture, Swift, signing mode, and available metrics.
- [ ] Map every acceptance criterion to scenario IDs and evidence paths.

## Module and command checks

Prioritize high-risk ownership and behavior scenarios:

- [ ] A1–A2: dependency direction and no GUI-binary annotation handoff.
- [ ] C1–C2: command compatibility, ordered batches, fields, limits, and errors.
- [ ] C3–C4: publication integrity, concurrency, failures, and opening outcomes.
- [ ] R1–R2: rendering styles, DPI, anchors, grayscale, and 16-bit precision.
- [ ] F1: real fonts and containing-installation resource resolution.
- [ ] S1–S2: shared full configuration interpretation without writes/lifecycle.

## Integration and regression checks

Preserve the surrounding application and distribution behavior:

- [ ] R3/S3: editor/history and live Settings regressions.
- [ ] P1: existing capture/discovery deadlines and isolation suite.
- [ ] P2–P3: signed public-fixture workflow and side-effect observations.
- [ ] B1: stable signing, bundled layout, relevant packaging checks.
- [ ] N1: same-host timing/resource comparison and responsiveness observation.
- [ ] W1–W2: site suite, truthful availability, CLI/skill examples and links,
  narrow/wide layout, keyboard access, and unchanged demo/install behavior.
- [ ] Confirm moved tests still run in CI and justify removed/replaced tests.
- [ ] Record native Intel/macOS 14, denied TCC, and cross-Space cells separately.

## Results and defect disposition

Finish with explicit outcomes rather than a blanket completion claim:

- [ ] Locked suite passes; report exact counts, commands, and failures.
- [ ] Report changed-critical-path line/branch coverage or metric limitations.
- [ ] All acceptance/high-risk scenarios have evidence or a blocked reason.
- [ ] Record each defect with reproduction, severity, and affected scenario IDs.
- [ ] Re-run impacted checks after fixes; distinguish unverified fixes.
- [ ] No unresolved critical/high defects; document remaining lesser defects.
- [ ] No screenshot titles, credentials, or personal browsing content published.
- [ ] Update only the QA ticket and intended evidence; retain unrelated files.
- [ ] Provide final pass/fail/blocked recommendation without merging or releasing.

## Planning estimates and assignment

One fresh QA session owns execution. Group effort by commands/ownership,
rendering/configuration, and signed integration; each is medium relative size.
Hardware and fresh-permission checks have external availability dependencies.
Do not invent historical velocity, story-point durations, or staffing needs.
Create follow-up defects only for actual findings, using repository labels and
priorities rather than introducing web-specific testing taxonomies.
