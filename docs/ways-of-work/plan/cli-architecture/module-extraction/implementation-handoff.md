# CLI extraction implementation handoff

This handoff identifies the integrated implementation prepared for independent
QA. It records source review and compile-only evidence, not runtime acceptance.
Read the approved specification and plan documents in this checkout.

Publication update: the candidate identity below records the pre-commit
implementation snapshot. Before committing, the branch fast-forwarded to
`dd0cd35` to retain the remote release synchronization. For subsequent QA, pin
the published extraction commit and any current dirty diff instead of treating
the historical manifest as the current checkout identity. The signed build was
installed with user approval, and a fresh agent completed a private capture and
annotation walkthrough; the user viewed and approved the result. Automated and
independent acceptance QA remain pending. No private captures are included here.

## Candidate and scope

The final integration checkout is
`/Users/dartsiukhou/dev/personal/vishot-agent-annotations`, branch
`integration/agent-annotations`. Its base and exact HEAD are both
`bcae50da04b0ed75aae1f6fe720b51f90b697b20`. Rendering, configuration, CLI,
bundled integration, landing-page changes, and review fixes are present together
as uncommitted working-tree content. HEAD alone does not identify this candidate.

Final identity computation output:

```text
HEAD=bcae50da04b0ed75aae1f6fe720b51f90b697b20
CHANGED_PATHS=96
MANIFEST_GIT_BLOB=d79f69046687710e3fffe8ae083579002a331fe6
MANIFEST_SHA256=850b39e25caaaba62b410ccd2ba40e8b90b5b5871738fc23352bb1711b5a657d
```

### Reproduce the content identity

From the integration checkout, run `python3 -B scripts/candidate-identity.py`.
The command prints the canonical manifest followed by the identity output above.
It reads Git and candidate files without staging or writing Git objects.

The versioned `vishot-candidate-v1` algorithm is implemented in that included
script. It uses these Git commands with pathspec exclusions applied before any
file content is read:

```sh
git rev-parse HEAD
git diff --name-status --no-renames --no-ext-diff --no-textconv -z HEAD -- <paths>
git ls-files --others --exclude-standard -z -- <paths>
git hash-object --no-filters -- <path>
git hash-object --no-filters --stdin
git hash-object --stdin
```

Here `<paths>` is `.` followed by a `:(top,exclude)` pathspec for each exclusion
below. The diff compares HEAD directly to disk, so tracked modifications,
additions, deletions, and mode changes are covered whether staged or unstaged.
Renames are represented as deletion/addition. All nonignored untracked files
outside the exclusions are intended candidate inputs, including source, tests,
documentation, planning, and the identity script itself. Ignored build output
and Git metadata are not candidate inputs.

The manifest contains the format, full HEAD, exact exclusion list, and records
sorted by repository-relative path. Each record is
`[status, mode, Git blob hash, path]`; statuses are Git's HEAD-to-disk status or
`??` for untracked files. Deleted files use `-` for mode and hash. Files use
`100644` or `100755`; symlinks use `120000` and hash their link text without
following the target. Raw file bytes are hashed without Git filters. The
canonical JSON uses sorted keys, ASCII escaping, compact separators, and one
final newline. Its SHA-256 and Git blob hash identify the manifest; HEAD supplies
the unchanged tracked content and original contents of deleted files.

The explicit exclusions and their roles are:

- `.vishot` and its entire subtree: private capture data, never read or hashed.
- `docs/ways-of-work/plan/cli-architecture/module-extraction/implementation-handoff.md`:
  this evidence and identity carrier, excluded to avoid self-reference.
- `docs/site-cli-qa.md`: the site QA procedure and matching identity carrier,
  excluded for the same reason. Neither handoff's bytes are claimed by the hash.

Any included content or HEAD change requires recomputation and updating both
handoffs before QA. Handoff-only corrections do not change this content identity.

Use the shared tracker explicitly:
`BEADS_DIR=/Users/dartsiukhou/dev/personal/vishot/.beads`.
The parent owns ticket closure and the subsequent independent QA session.

## Dependency graph

SwiftPM target edges point toward shared owners:

```text
VishotCLI -> VishotCLIExecution -> VishotConfiguration -> VishotRendering
                              -> VishotRendering
                              -> VishotAgent
VishotConfiguration -> TOMLKit -> CTOML / vendored toml++
Vishot -> VishotRendering
       -> VishotConfiguration
       -> VishotAgent
       -> TOMLKit (conservative app-only configuration editing)
AgentServiceFixture -> VishotAgent
```

Shared rendering uses AppKit/CoreText/CoreGraphics/ImageIO; configuration uses
Carbon key metadata for existing shortcut validation. Neither owns app
lifecycle or imports an executable. The CLI execution target has no GUI target
dependency. GUI theme construction stays in `Vishot/Theme.swift`,
`PixelTheme.swift`, and `SmoothTheme.swift`; screenshot treatment factories live
only in `VishotRendering/AnnotationStyle.swift`.

## Resource and configuration behavior

The process adapter uses `_NSGetExecutablePath`, resolves symlinks, and passes
the executable URL to command execution. `AgentEndpoint.containingApp` resolves
the canonical `*.app/Contents/Helpers` layout. Fonts use that installation's
`Contents/Resources/Fonts`; release version uses its `Contents/Info.plist`.
Neither lookup uses `Bundle.main`, PATH, or the workspace as a resource root.
The workspace still selects `.vishot/` publication. No separate distribution,
resource bundle, version source, or executable-name change was introduced.

Annotation validates arguments, resolves resources, reads input, registers the
four bundled font files, takes a configuration snapshot, then resolves the
treatment. Registration returns success only when the exact bundled files
register in the process (or already have process scope) and required named
fonts resolve. A failed bundled registration returns `rendering_failed`, exit
9, before publication. Raw app development builds retain their existing
fallback behavior. Real signed-bundle font behavior still requires QA.

`AppSettings` supplies one full TOML interpretation and missing-file defaults.
Legacy `theme = 'clean'` maps to Smooth/`clean` with Dark appearance; explicit
modern preferences override the legacy choice. Invalid legacy, shortcut,
history, watermark, or appearance values still reject an otherwise valid style.
The CLI maps snapshot errors to `invalid_arguments`, exit 2, without writing,
watching, registering hotkeys, or using the app's active session. Conservative
editing, file watching, last-good state, and session deferral remain app-owned.
Saved history IDs remain `pixel`/`clean`; CLI reports `pixel`/`smooth`.

## Review findings and fixes

The integrated review found duplicate selectable style-to-treatment mapping in
the shared preference and the two shipping GUI definitions. `PixelTheme` and
`SmoothTheme` now derive their treatment IDs from
`VisualStyle.pixel.annotationID` and `VisualStyle.smooth.annotationID`.
`VishotConfiguration/Preferences.swift` is the authoritative selectable mapping
used by the CLI and app. GUI factories and the custom `ThemeDefinition`
initializer remain independently extensible; single-appearance fixtures can
still explicitly reuse `.clean`. Persisted `ThemeID` values are unchanged.

The app rendering integration assertion now checks both shipping styles and
appearances against the shared treatment selected by the CLI, including rendered
pixel equality. Existing `ThemeCatalogTests` custom definitions and their
assertions remain intact. The adding-themes guide derives the GUI treatment
from shared configuration instead of advising duplicate mapping synchronization.
These assertions compile but have not been executed.

The review also found sibling-worktree candidate pointers in both handoffs.
They now name this integrated path, branch, HEAD, and content-addressed working
tree, including intended untracked planning files. No commit was created.

## Contracted paths

The integrated extraction removes `execv` annotation routing, the private
`--vishot-agent-annotate` argument, the app entry-point annotation branch,
`AnnotationCommand.run`, and `AgentAnnotationArguments` in transport.
Command arguments and process exit mapping now belong to CLI execution.
The `SettingsStore.annotationStyleSnapshot` bridge and app-owned duplicate
renderer/model/encoding/font/treatment definitions are gone. There are no
forwarding targets or temporary type aliases. Capture's background argument,
transport, authorization adapter, deadlines, and output publication remain
the existing interfaces.

## Migrated assertion inventory

This inventory compares original `bcae50d` tests with the integrated extraction.
Numbers are source-declared test methods, not executed/discovered pass counts.
No original behavioral assertion is intentionally dropped; interface spelling
and imports change with ownership. All five targets compiled, but runtime
discovery and assertions remain for the separate QA session.

| Original interface/file | Owning interface/file after extraction | Preserved assertions |
| --- | --- | --- |
| `VishotTests/EditHistoryTests` (4) | `VishotRenderingTests/EditHistoryTests` (4) | Undo/redo, empty history, redo invalidation, snapshots unchanged. |
| `VishotTests/PixelArtTests` (7) | `VishotRenderingTests/PixelArtTests` (7) | Cell geometry, connected/reverse lines, triangle tip/fill, corners, tiny/small/narrow outlines unchanged. |
| `VishotTests/TextLayoutTests` (1) | `VishotRenderingTests/TextLayoutTests` (1) | Multiline caret and text bounds unchanged; catalog lookup uses shared owner. |
| `VishotTests/ExportTests` (13) | `VishotRenderingTests/ExportTests` (11), plus the two integration tests below | Exact CLI text anchors, 1x/2x, multiline, preview/export parity, cell shadows, vector antialiasing, source precision, crop math and dimensions, identity/no-redraw preserved. |
| `ExportTests.testCLIArrowAndRectangleGeometryStyleAndDPIThroughSharedExport` | `VishotCLIExecutionTests/RenderingIntegrationTests` | Original body retained: ordered pixel-to-point conversion, shaft thickness, arrowhead direction, rectangle interior, style difference, dimensions, no watermark. |
| `ExportTests.testInterfaceAppearanceDoesNotRestyleScreenshotMarkup` | `VishotTests/RenderingIntegrationTests` | Original body retained: equal markup pixels across appearances, different GUI panel colors. |
| `VishotTests/AnnotationCLITests` (9) | `VishotCLIExecutionTests/AnnotationCLITests` (13) | All original compiled-helper argument/JSON/image/text budgets, indexed problems, DPI, anchors, dimensions, source preservation, concurrency, ordering, symlink refusal, prior output, no public image bytes. Fixture no longer copies GUI executable. Four added tests cover whole config, real fonts without GUI/service, version lookup, and missing fonts. |
| `VishotTests/MarksCLITests` (6) | `VishotCLIExecutionTests/MarksCLITests` (6) | Bodies unchanged: rectangle interior, all indexed invalid geometry, nonfinite/nonnumeric values, no clamping/skipping, colors/default, mixed ordering and both JSON sources. |
| `VishotTests/PNGPrecisionCLITests` (2) | `VishotCLIExecutionTests/PNGPrecisionCLITests` (2) | Bodies unchanged: entire untouched 16-bit low-bit band, colored marks, grayscale RGB conversion and untouched samples. |
| `VishotTests/OpeningTests` (5) | `VishotCLIExecutionTests/OpeningTests` (5) | All assertions retained: no opening on validation/render/encode/write failure, complete file before accepted open, exit 11 retains saved file, default no-open, explicit switch validation. Parser/exit mapping now use CLI-owned types. |
| `VishotTests/SettingsTests.testThemeDefaultsAndValidation` | `VishotConfigurationTests/SettingsTests.testThemeDefaultsAndValidation` | Original defaults, legacy clean, invalid values, and error-field assertions retained. |
| `SettingsTests.testStandardTOMLLoadsPhysicalShortcutAndWatermark` | Same method in `VishotConfigurationTests/SettingsTests` | Original multiline TOML, physical key/modifiers, watermark, and defaults assertions retained. |
| Parse portion of `SettingsTests.testIndependentAppearanceAndStyleCompatibility` | Shared test with same name, plus `testDefaultsAndGeneratedSourceAgree` | Legacy/explicit precedence and four invalid inputs retained. Empty/default appearance follows full parsed-value equality and explicit `.system` assertion. Editing assertions remain app-owned under `testLegacyThemeEditingPreservesIndependentAppearanceAndStyle`. |
| Validation portion of `testInvalidValuesAndUnsafeEditsDoNotSilentlyChangeMeaning` | `VishotConfigurationTests/SettingsTests.testInvalidValuesRejectTheFullConfiguration` | All seven invalid source cases retained. Conservative-edit assertions remain in app `testUnsafeEditsDoNotSilentlyChangeMeaning`. |
| Default assertions in `testHistoryShortcutIsOptInAndCanBeAssignedClearedAndReassigned` | Shared `testDefaultsAndGeneratedSourceAgree` | Both parsed sources equal defaults whose history shortcut is explicitly nil. Assignment, clearing, and reassigning remain app-owned. |
| Invalid-history assertions in app history edit test | Shared `testHistoryRetentionAndOptionalShortcutValidation` | Same unsupported retention and conflicting default key rejection retained. Editing, comments, and unrelated content stay app-owned. |
| `VishotTests/ThemeCatalogTests` (3) | Same app suite (3) | Single-appearance fixture's resolved identity/label now read `definition`; selectable identity equality reads `definition.id == style.rawValue`. Appearance, annotation mapping, configuration, labels, and positive sizing checks retained. |

Other modified app tests only gain imports for shared types: annotation-style
history, editor area, frozen preparation, history browser/persistence/read
lifetimes and history, screenshot completion, theme outline, and watermark.
Their assertions remain unchanged. `VishotAgentTests` capture/discovery bodies
and `AgentServiceFixture` remain unchanged. App CLI-installation tests still
exercise installation/replacement behavior through the app-owned interface.

New shared configuration tests cover identity mapping, appearance resolution,
modifier normalization/conflict, all retention choices, read-only snapshot
behavior, missing files, unreadable files, and invalid unrelated fields.
New CLI tests cover early argument rejection without installation resolution,
startup error preservation, every existing exit code, and configuration-error
adaptation. The bundled slice strengthens font coverage with an unrelated CWD
and checks output placement; version coverage uses a relative helper symlink,
space-containing paths, conflicting CWD metadata, and changed app metadata.

## Packaging and CI review

`scripts/build.sh` still builds both native executables with locked resolution,
copies the same four fonts and license files, signs nested helper first with
the stable configured identity, then seals/verifies the app. Only its font
ownership comment changes. The TOML dependency remains pinned at 0.6.0; no
dependency or lockfile change is needed. Notices now explicitly cover both
executables and the existing MIT notices remain intact.

`scripts/package.py` already validates both executables' native architecture,
macOS 14 load commands, system-only dynamic libraries, nested signatures,
matching teams, exact font/license bytes, and app-matching version. The package
test's version scenario now runs through a symlink from an unrelated directory.
These scripts were reviewed, not executed.

CI remains unfiltered `swift test --force-resolved-versions`, so new test
targets participate. Native package jobs use the same test command with their
architecture triple. `scripts/ci/changes.mjs` already includes all `Sources/`,
`Tests/`, manifest, resource, and packaging changes. The five required names
remain `App tests`, `Site tests`, `PR title`, `Release tooling`, and
`Package checks`. No workflow or gate rename is required.

## Actual compile-only evidence

The final integration checkout performed these checks on October 27, 2026:

- `swift build --force-resolved-versions --build-tests`: exit 0,
  `Build complete! (3,45 sec)`. App, helper, fixture, and all five test targets
  compiled, including the updated app/shared rendering assertion.
- Host: native arm64, macOS 26.7.1 (25G241), Apple Swift 6.4
  (`swiftlang-6.4.0.34.1`, clang `2100.3.34.1`). This is not the CI-pinned
  Xcode 16.4 / Swift 6.1.2 environment.
- `git diff --check`: exit 0; no whitespace errors.

The review-fix session follows the user's compile-only policy: no tests, smoke
checks, helper/app runtime, package/build scripts, signing, browser checks,
installation, or launch. Test compilation does not execute assertions. No
staging, commits, merge, push, PR, deploy, reset, stash, or clean operation runs.
Earlier slices likewise reported no runtime acceptance; red/green execution
remains deferred to the separately authorized QA session.

## Independent QA gaps and next actions

All acceptance outcomes remain unverified at runtime. Use scenario IDs from
the approved test strategy, not historical annotation/capture results:

- A1–A2/C1–C4: run locked tests, confirm actual discovery counts, independent
  helper execution without GUI binary/service, publication and opening behavior.
- F1/B1: exercise real fonts, repeated registration, symlink/relocation/space
  paths, metadata replacement, missing-resource failure, stable signed helper
  and app, release architecture/deployment target, and package rejection suite.
- R1–R3/S1–S3: inspect Pixel/Smooth at 1x/2x, precision, anchors, editor preview,
  old history, Settings watching/editing/session deferral, and delayed output.
- P1–P3: verify deadlines/isolation and signed non-private capture/read/annotate/
  read workflow; observe clipboard/history, watermark, UI, and authorization.
- N1: same-host baseline and timing/resource comparisons remain unavailable.
  No runtime performance or coverage metrics were collected.
- W1–W2: landing-page work is integrated; the site suite and browser checks
  remain pending. See [the site handoff](../../../../site-cli-qa.md).
- Native Intel, macOS 14 runtime, fresh denied-TCC, cross-Space, Gatekeeper,
  quarantine, display-specific visual checks, and actual default-app display
  remain distinct hardware/manual coverage cells. Opening acceptance alone
  does not establish visible display.

No runtime defect is claimed fixed-and-verified by compilation. The independent
QA session must verify the identity above before recording pass/fail/blocked
evidence and defects. Recompute it if included content changes.
