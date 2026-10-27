# Extract CLI ownership and shared screenshot modules

This specification defines a behavior-preserving extraction of CLI execution,
screenshot rendering, and immutable configuration interpretation. It records
the design approved on October 27, 2026; it does not claim implementation or QA
completion. The reference implementation is annotation commit `bcae50d` in
[PR #11](https://github.com/dartyuhov/vishot/pull/11).

## Problem statement

Vishot has a separate CLI executable, but annotation execution belongs to the
GUI target. The helper replaces its process with the app executable through a
private startup argument. Reusing the renderer also reaches GUI theme and live
Settings ownership. Understanding and testing one local command consequently
requires navigating two executable entry paths and unrelated application code.

## Solution

Give CLI commands independent module ownership. Both the CLI and app consume
shared screenshot rendering and immutable configuration interpretation through
normal in-process dependencies. Retain the bundled CLI distribution and the
signed app's existing capture responsibility.

## User stories

The extraction serves existing users, agents, and maintainers:

1. As an agent, I want unchanged commands so existing workflows keep working.
2. As an agent, I want annotation to run within the CLI process so a local PNG
   operation doesn't execute the GUI binary.
3. As a user, I want Pixel and Smooth results unchanged after extraction.
4. As a user, I want my original PNG and its dimensions preserved.
5. As a user, I want grayscale color marks and 16-bit precision preserved.
6. As an agent, I want the same indexed validation errors and exit statuses.
7. As a user, I want annotation to remain independent of capture permissions.
8. As a user, I want save-only defaults and explicit default-app opening.
9. As a user, I want saved output retained when opening fails.
10. As a user, I want clipboard and Capture history unchanged by CLI commands.
11. As a user, I want discovery and capture to keep bounded background behavior.
12. As a user, I want editor preview and export to share annotation rendering.
13. As a user, I want editable screenshots to retain saved annotation treatments.
14. As a user, I want Appearance to remain independent of annotation Style.
15. As a maintainer, I want one configuration interpretation and legacy mapping.
16. As a user, I want invalid configuration to retain its current rejection
    behavior, including unrelated invalid shortcut/history preferences.
17. As a maintainer, I want live Settings lifecycle to remain app-owned.
18. As an agent, I want bundled fonts to resolve from the containing installation
    when invoked through a symlink or from an unrelated working directory.
19. As a maintainer, I want command tests to use CLI-owned interfaces without
    importing the GUI executable target.
20. As a reviewer, I want independent QA evidence tied to an exact revision.
21. As a visitor, I want the landing page to explain CLI capture, annotation,
    and the agent skill with accurate commands and release availability.

## Implementation decisions

The following responsibility allocation is approved; concrete type names and
method signatures remain implementation decisions:

- A CLI-owned execution module handles command parsing, dispatch, annotation
  orchestration, structured results, and exit semantics. Its executable is a
  small process adapter for arguments, stdout, resource discovery, and lifecycle.
- A shared screenshot-rendering module owns annotation geometry, treatments,
  measurement, rendering, required font support, and image encoding. It has no
  dependency on either executable, picker panels, or live Settings.
- A shared immutable-configuration module owns parsing, defaults, validation,
  and compatibility interpretation. Preserve full-configuration rejection.
  Configuration writing, watching, hotkey registration, and session deferral
  remain app-owned unless a small shared value definition is necessary.
- Keep one treatment registry/mapping; do not duplicate Pixel/Smooth definitions
  in the CLI. Keep GUI appearance construction outside shared rendering.
- Remove process replacement and the app-only annotation startup route after
  in-process execution is wired. Do not retain obsolete forwarding modules.
- Preserve the existing capture transport and signed app adapter. Annotation
  doesn't connect to that transport or invoke capture authorization.
- Preserve versioned command/results/errors, limits, atomic publication,
  concurrency behavior, DPI policy, exact text anchors, and drawing order.
- Preserve saved `pixel`/`clean` treatment identities, selectable `smooth`
  mapping, frozen resolved styles, and interactive grid snapping.
- Register fonts before resolving treatment. The bundled helper must locate
  the containing app's resources without relying on GUI executable startup.
- Use expand–migrate–contract where the shared types have a wide blast radius.
  Temporary compatibility paths must have a defined removal point.
- Keep small internal adapters only where behavior genuinely varies, such as
  accepted/rejected opening and real/fixture capture; avoid protocol-per-file
  abstractions around ordinary computation or local files.
- Update the landing page's planned CLI entry to describe discovery, exact-ID
  capture, image inspection, annotation, and optional opening. Explain bundled
  CLI/skill access and link to documentation. Advertise only capabilities in
  verified public releases; distinguish unreleased annotation from released
  capture when necessary. Preserve the site's visual identity and install gates.

## Testing decisions

The user requested planning with their supplied `breakdown-test` skill and test
execution in a separate session. The detailed strategy is the authority for
test execution; this planning session runs no application tests.

- Prefer observable behavior through the compiled CLI and owning module
  interfaces. Check architecture with the build dependency graph and source
  review rather than brittle private-symbol string assertions.
- Move meaningful rendering/configuration assertions with their implementation;
  retain compiled CLI coverage and app integration coverage. Replace duplicated
  tests only after equivalent behavior remains covered.
- Reuse generated PNGs, temporary workspaces, isolated settings, controlled
  capture handlers, and injected opening outcomes. No browser framework is
  required for this native macOS extraction.
- Separate-session QA must distinguish automated results, visual observations,
  OS opening acceptance, and unavailable hardware/manual checks.

## Out of scope

No standalone CLI distribution, new annotation marks, schema changes, new
configuration tolerance, capture redesign, dependency framework, theme loading,
release publication, or unrelated architecture cleanup is included.

## Further notes

This is the approved extraction plan plus the requested landing-page ticket,
not authorization to implement, install,
commit, merge, push, or update PR #11. Those actions require a subsequent request.
Existing annotation/capture verification gaps and tracker issues stay distinct.

Planning and QA artifacts live under
`docs/ways-of-work/plan/cli-architecture/module-extraction/`:
[technical breakdown](../ways-of-work/plan/cli-architecture/module-extraction/technical-breakdown.md),
[implementation plan](../ways-of-work/plan/cli-architecture/module-extraction/implementation-plan.md),
[project plan](../ways-of-work/plan/cli-architecture/module-extraction/project-plan.md),
[test strategy](../ways-of-work/plan/cli-architecture/module-extraction/test-strategy.md),
[test checklist](../ways-of-work/plan/cli-architecture/module-extraction/test-issues-checklist.md),
[QA plan](../ways-of-work/plan/cli-architecture/module-extraction/qa-plan.md), and
[separate-session handoff](../ways-of-work/plan/cli-architecture/module-extraction/qa-session-handoff.md).
