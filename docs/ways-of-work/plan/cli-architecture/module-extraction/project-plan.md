# CLI extraction project plan

The user approved five tickets and added landing-page CLI coverage. Beads is the project
tracker; no GitHub issue duplication is needed. The authoritative requirements
are in the [specification](../../../../specs/cli-module-extraction.md).

Beads epic: `vishot-1us`. Children `vishot-1us.1` through `vishot-1us.6`
correspond to the six slices below. All use spec identifier
`cli-module-extraction`.

## Approved work breakdown

Each slice delivers an observable result, including module ownership where that
is the feature under review:

| Slice | Deliverable | Blocked by | Planning size |
| --- | --- | --- | --- |
| 1 | Shared rendering used by the app without changed output | None | Medium |
| 2 | Shared immutable configuration with existing app/CLI semantics | None | Medium |
| 3 | In-process CLI annotation; no app executable handoff | 1, 2 | Medium |
| 4 | Bundled resources, packaging, documentation, and tests integrated | 3 | Medium |
| 5 | Landing-page CLI/skill explanation with truthful availability | 4 | Small–medium |
| 6 | Independent acceptance report including site checks | 4, 5 | Medium, hardware-dependent |

Sizes are relative uncertainty estimates, not measured durations or delivery
promises. Rendering/theme and configuration type placement are the main risks.
Tasks 1 and 2 have overlapping integration files even though neither logically
blocks the other; coordinate edits in a later implementation session.

## Execution policy

All published tickets start open and unclaimed with `ready-for-agent`; blockers
control availability. Publication doesn't start implementation. Existing
annotation and capture tickets aren't modified or closed by this plan.

The QA ticket is reserved for a separate session. Its subtasks are the scenario
groups in the [test checklist](test-issues-checklist.md), not extra implementation
tickets. Beads records active progress and evidence links. Don't copy changing
tracker status into this plan or treat the spec epic as a blocking prerequisite
for its own children.
