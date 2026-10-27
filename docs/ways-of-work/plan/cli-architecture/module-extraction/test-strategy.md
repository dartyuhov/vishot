# CLI extraction test strategy

This is a test plan, not an execution report. It applies the user-specified
`breakdown-test` skill to the native macOS
[CLI extraction](../../../../specs/cli-module-extraction.md). Run acceptance
tests in a separate session after implementation and integration are ready.

## Scope and quality objectives

Verify unchanged user-visible behavior and genuinely independent module
ownership. The historical reference is `bcae50d`: 284 Swift tests, signed-build
smoke checks, and existing contract documentation. These results establish
prior art only; they don't verify the future extraction.

- Account for 100% of acceptance criteria and high-risk scenarios with a pass,
  defect, or explicit blocked result.
- Require all applicable automated checks to pass, not a 95% pass-rate waiver.
- Require no unresolved critical/high defects for acceptance. Treat lost image
  precision, changed schema, broken fonts, and capture side effects as high risk.
- Target greater than 80% line coverage and 90% branch coverage in changed
  critical paths where tooling reports those metrics. Report unavailable branch
  metrics honestly; don't invent coverage or add tests solely to reach a number.
- Preserve useful behavior coverage when moving tests. Test outcomes through
  owning interfaces; don't mirror private methods or count renamed files.

## Risk assessment

Use failure impact to prioritize execution:

| Risk | Priority | Mitigation and observation |
| --- | --- | --- |
| CLI still executes or imports GUI implementation | Critical | Build graph review plus local annotation without a GUI executable in controlled CLI layout |
| Font lookup changes when executable changes | High | Actual bundled fonts through helper, symlink, spaces, and unrelated working directory |
| Shared rendering changes pixels or saved identities | High | Generated fixtures, pixel comparisons, legacy history and preview/export checks |
| Duplicate/partial configuration interpretation | High | Shared parser and app/CLI decision table, including unrelated invalid settings |
| Publication/open order changes or output lost | High | Real temporary workspaces, concurrent calls, controlled opener outcomes |
| Capture transport/permissions regress | High | Existing compiled fixtures, bounded failure cases, signed non-private capture |
| Test moves silently remove coverage | High | Before/after scenario inventory; explain every removed assertion |
| Latency or memory increases | Medium | Same-host before/after repeated samples and resource observations |
| Unsupported hardware reported as verified | Medium | Explicit OS/architecture evidence matrix and blocked results |

## ISTQB test design

The techniques below produce a finite scenario set rather than exhaustive
combinations of every annotation field:

| Technique | Application |
| --- | --- |
| Equivalence partitioning | Inline/file JSON; Pixel/Smooth; RGB/grayscale/16-bit; valid/invalid config; save/open |
| Boundary value analysis | Coordinate edges, zero geometry, DPI thresholds, image/JSON/text/batch limits, timeout endpoints |
| Decision tables | Missing/legacy/modern style × valid/invalid unrelated config; save success × opening requested/accepted/rejected |
| State transitions | Validate → render → encode → publish → optionally open; abandon/timeout capture → discard late result |
| Experience-based exploration | Relocated bundle, symlink invocation, font fallback, small outlines, old history, non-Latin picker input |

Boundary cases include below/at/above accepted limits where affordable. Use
small controlled fixtures and validation-only inputs rather than allocating
maximum-sized bitmaps unnecessarily. Existing limits remain as documented in
the [CLI contract](../../../../agent-cli.md).

## Coverage matrix

Stable scenario IDs connect execution evidence to acceptance requirements:

| ID | Type | Observable result and test surface |
| --- | --- | --- |
| A1 | Structural | Acyclic shared modules; neither imports an executable or live app lifecycle; CLI execution imports no GUI target |
| A2 | Structural/integration | Compiled local annotation runs without GUI binary or capture endpoint in a controlled containing layout |
| C1 | Functional | Same commands/options, versioned JSON, indexed errors, exit statuses, and no public image bytes |
| C2 | Functional | Inline/file sources, mixed order, six colors/default, exact pixel geometry, full-batch rejection |
| C3 | Reliability | Unique complete outputs, original/prior files preserved, concurrent calls, symlink/unwritable destination rejection |
| C4 | Reliability | No-open default; accepted open; failed open exit 11 retains readable result; no open on earlier failures |
| R1 | Functional/regression | Pixel/Smooth, 1x/2x, supported/fallback/rejected DPI, top-left text anchors and interactive snapping |
| R2 | Functional/regression | Grayscale colored marks, 16-bit untouched low bits, dimensions, arrowhead direction, rectangle interiors |
| R3 | Integration | Editor preview/export/crop, saved treatment identities, immutable session styles, legacy Capture history |
| F1 | Integration/portability | Registered bundled fonts, no silent fallback in signed bundle, symlink/relocation/space-path invocation |
| S1 | Functional | Defaults, legacy theme mapping, modern style/appearance, malformed TOML, unknown style |
| S2 | Functional/regression | Valid style with invalid shortcut/history rejects annotation; reads don't write files or register hotkeys |
| S3 | Integration | App conservative edits, watching, session deferral, and hotkey lifecycle remain intact |
| P1 | Regression | Discovery/capture exact target, permission denial, startup/deadlines/cancellation/late-result isolation unchanged |
| P2 | End-to-end | Signed fixture capture → built-in image read → annotate same PNG → image read; explicit opening observed separately |
| P3 | Integrity | No watermark, clipboard/history writes, picker/setup UI, or extra authorization for local PNG annotation |
| B1 | Packaging | Bundled helper/app/font layout, matching stable signatures, release version, package checks |
| N1 | Performance | Same-host local annotation timings/resources and interactive responsiveness during concurrent capture |
| W1 | Functional/integration | Served landing page has correct CLI/skill examples, links, and verified release availability; existing install gates remain |
| W2 | Usability/regression | CLI content readable at narrow/wide widths, keyboard-accessible links/controls; demos and reduced-motion behavior preserved |

## ISO 25010 priorities

Quality assessment uses the characteristics relevant to this extraction:

| Characteristic | Priority | Validation |
| --- | --- | --- |
| Functional suitability | Critical | C1–C2, R1–R2, S1–S2 |
| Maintainability | Critical | A1–A2, test ownership inventory, no duplicate renderer/parser |
| Reliability | High | C3–C4, P1 |
| Compatibility | High | R3, S3, saved identities and existing CLI clients |
| Security/integrity | High | P3, symlink refusal, private fixtures, no secrets in evidence |
| Portability | High | F1, B1; macOS 14/Intel when hosts exist |
| Performance efficiency | Medium | N1 and existing capture deadline tests |
| Usability | Medium | Actual fonts/marks, editor controls, legible default-app result |

The added landing-page ticket needs the existing Node site suite and focused
browser checks for content, links, keyboard access, and responsive layout.
Use available browser tooling; no new automation framework is required. Native
keyboard and editor regressions use existing AppKit tests and hands-on checks.

## Environments and fixtures

Use Swift/XCTest, the existing capture fixture adapter, generated PNGs, real
temporary files, isolated configuration homes, and controlled opening adapters.
Keep fixture content non-private. Retain raw evidence outside the repository;
publish only redacted observations and intended fixture images.

Primary environment: native Apple Silicon macOS host with Swift 6 and the
existing signing identity. Record actual OS/build/tool versions. Native Intel
and macOS 14 runtime are separate coverage cells; cross-compilation is not
runtime evidence. Fresh denied-TCC tests require an isolated permission context.

Compare before/after visual output using identical registered fonts, fixture
pixels, config, and platform. Prefer exact comparisons for stable raster cases;
document tolerance for system-font/OS differences. Don't compare captures made
at different times as if they were identical inputs.

## Performance and CI

Record at least ten warm local-annotation runs per style against one fixed
fixture on the same host, plus a cold run. Compare median and p95 with baseline;
investigate a repeatable increase above 20% and report absolute durations.
This is a regression investigation trigger, not a new product latency SLA.
Observe memory for representative 8/16-bit images; preserve existing bounds.

Run the locked Swift suite, `npm test --prefix site` using the pinned site Node
version, and relevant signed packaging checks. Existing CI
must discover tests after target moves; update only affected build/packaging
integration. Keep five required CI check contracts intact. Obtain coverage with
available Swift tooling in the QA session, and explain unsupported metrics.

## Completion

Use the [QA gates](qa-plan.md), [checklist](test-issues-checklist.md), and
[separate-session instructions](qa-session-handoff.md). Evidence must identify
the tested revision and distinguish baseline history from extraction results.
