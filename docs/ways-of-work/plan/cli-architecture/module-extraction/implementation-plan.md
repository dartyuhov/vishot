# CLI extraction implementation plan

Use the six approved slices below. Active assignment, status, and blockers live
in Beads, not this document. The
[specification](../../../../specs/cli-module-extraction.md) defines behavior;
the [QA plan](qa-plan.md) defines independent completion evidence.

## Sequence

The two initial extractions can proceed independently, then converge:

```text
1 Shared screenshot rendering ─┐
                              ├─ 3 CLI command ownership
2 Immutable configuration ────┘       │
                                     4 Bundled integration/test migration
                                     │
                                     5 Landing-page CLI explanation
                                     │
                                     6 Independent QA (separate session)
```

1. **Share screenshot rendering across app and CLI.** Expand shared ownership,
   migrate editor/history consumers, and remove redundant drawing ownership.
   Keep saved treatments and image precision stable. Inventory relevant tests.
2. **Share immutable configuration interpretation.** Migrate app and annotation
   configuration reading to one interpretation. Keep defaults, legacy mapping,
   full validation, and live Settings behavior stable. Avoid duplicating TOML.
3. **Give CLI commands independent ownership.** Move parsing and orchestration
   behind CLI-owned interfaces; wire shared modules directly. Remove `execv`
   annotation routing and the app-only dispatch branch. Retain capture transport.
4. **Finish bundled integration and test migration.** Resolve resources from the
   actual containing installation, update packaging/docs/skill descriptions,
   migrate tests, and contract all temporary compatibility paths. Prepare the
   exact-revision QA handoff and evidence inventory.
5. **Update the landing page for the CLI.** Explain actual discovery, capture,
   annotation, optional opening, and skill access with truthful public-release
   availability. Preserve existing demos, installation gates, and responsive
   styling; update served-page assertions and relevant documentation links.
6. **Execute independent QA in a separate session.** Use the approved strategy
   against the completed implementation. Record failures as defects and recheck
   affected scenarios after fixes; include site tests and browser checks, and
   never substitute old annotation evidence.

## Implementation handoff requirements

Before a later QA session starts, the implementation session supplies:

- An exact revision and working-tree diff identity, including uncommitted changes.
- A dependency graph and list of migrated tests with preserved coverage.
- Resource-location and configuration-compatibility notes.
- A list of removed process-routing paths and temporary compatibility paths.
- Known defects and platform/manual gaps, without marking them passed.
- Any actual build/check evidence separately from planned QA execution.

This planning request doesn't start implementation. Future implementation may
prepare and migrate tests, but the independent acceptance run belongs to the
separate session requested by the user. Commit, push, merge, installation, and
PR changes require explicit authorization for that later work.
