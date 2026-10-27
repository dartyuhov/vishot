# CLI extraction technical breakdown

This document explains the module seams supporting the
[approved specification](../../../../specs/cli-module-extraction.md).
The source reference is `bcae50d`; names below describe responsibilities rather
than finalized target names.

## Existing friction

The current dependency paths identify the extraction work:

| Current path | Friction | Intended ownership |
| --- | --- | --- |
| CLI entry → `execv` → app entry → annotation command | Local annotation depends on two executable entry paths | CLI execution |
| Annotation model → theme catalog → complete GUI styling | Shared drawing reaches picker/panel appearance | Shared rendering, GUI appearance kept app-owned |
| Style snapshot → SettingsStore → full app configuration | Read-only interpretation belongs to a live lifecycle owner | Shared immutable configuration |
| ImageEncoding inside Capturer | Shared encoding is colocated with capture orchestration | Shared rendering |
| Fonts → Bundle.main | Helper execution changes resource context | Explicit containing-installation resource adapter |

## Target dependency direction

The app and CLI are peers consuming shared implementation:

```text
CLI executable → CLI execution → shared rendering
                              → shared configuration
                              → existing capture client / PNG publication

App executable → editor / Capture history → shared rendering
               → live Settings           → shared configuration
               → signed capture adapter  → existing transport
```

Shared rendering and configuration must not depend on either executable. Keep
the dependency graph acyclic. Put shared style identities and catalog mapping
at the lowest owning seam that avoids duplicating interpretation; do not move
the full GUI theme catalog merely to satisfy compilation.

## Dependency treatment

Dependencies need different verification, not a uniform protocol abstraction:

- **In-process:** geometry, validation, treatment values, and configuration
  interpretation. Test through their owning interfaces.
- **Local-substitutable:** generated PNGs, fonts, configuration files, temporary
  output directories. Exercise real encoding and file publication.
- **Owned process seam:** preserve the existing capture client and controlled
  handler adapter, including authorization and deadline semantics.
- **External platform adapter:** retain controlled opening acceptance/failure
  and signed macOS smoke checks. Acceptance doesn't establish visible display.

## Migration constraints

Wide shared-type moves use expand–migrate–contract on one integration baseline.
Do not fork renderer implementations. Preserve annotation point-space geometry,
pixel-coordinate conversion, exact CLI text anchors, and interactive snapping.
Move saved identities without changing encoded history. Preserve full TOML
validation, legacy theme mapping, and app-only conservative configuration edits.

AppKit and CoreText can remain shared rendering dependencies. Carbon shortcut
metadata may remain part of shared immutable configuration when necessary for
existing validation; actual global registration stays app-owned. This is native
macOS modularity, not platform-independent rendering.
