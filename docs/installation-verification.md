# Direct-download installation verification

The README's DMG installation and update guide is prepared, but public
installation readiness is **blocked**. No browser-quarantined first install,
replacement, Gatekeeper approval, or permission/restart behavior was observed
in this verification. Automated package checks aren't substitutes for those
checks.

## Candidate and environment

The following identifies the local candidate tested on October 18, 2026:

- Source commit: `2560a840f371abd94f66cfc82d73846b4574fa1e`, the shared base
  of `impl/vishot-1rq.5` and `integration/releases-site-homebrew` at test time.
- Bundle version/build: `0.1.0` / `0.1.0`.
- Native host: Apple Silicon (`arm64`), macOS 26.7.1 (build `25G241`).
- Toolchain: Xcode 27.1 (`27A9275`), Apple Swift 6.4, Python 3.15.0.
- Build target: `arm64-apple-macosx14.0`; signing explicitly ad-hoc (`-`).
- Distribution status supplied for this work: repository private, no public
  release or public Homebrew tap. No release was published during verification.

This is local package evidence, not a published release candidate or evidence
from the workflow's pinned Xcode 16.4 / Swift 6.1.2 environment. A later release
must be identified by its own exact commit and asset checksums when tested.

## Automated evidence

The existing public test boundaries in the release spec were used. No app
behavior or test interfaces were added for this documentation change.

| Command | Observed result |
|---|---|
| `swift test --force-resolved-versions --triple arm64-apple-macosx14.0` | 163 tests passed, zero failures. |
| `VISHOT_SIGN_IDENTITY=- ./scripts/build.sh` | Release app built; strict signature verification passed. |
| `build/packaging-venv/bin/python scripts/test-package.py` | All 7 package-boundary tests passed. |

The packaging virtual environment used the hash-locked, binary-only
requirements from `scripts/packaging-requirements.txt`. See
[packaging instructions](packaging.md#local-verification) for setup commands.
The build command did not use `install` or launch Vishot.

The package tests validated the real native signed bundle and a compressed,
read-only mounted DMG. They checked architecture, macOS 14 deployment metadata,
version/build, exact source commit, resources/notices, signature, Applications
shortcut, installation text, Finder layout, checksum, and manifest. Negative
cases rejected modified or incomplete installers and incorrect source identity.
The native Intel package tests were not run in this session.

A retained local DMG was also packaged and revalidated with this command:

```sh
build/packaging-venv/bin/python scripts/package.py package build/packages \
  --arch arm64 --version 0.1.0 --build 0.1.0 \
  --commit 2560a840f371abd94f66cfc82d73846b4574fa1e --adhoc
```

It returned `Validated build/packages`. The output is
`build/packages/Vishot-0.1.0-arm64.dmg`, with SHA-256
`e0cf5fc487ca8bbe0af8002e6f0747c46570ed7dd7bef0db2c745a41a12e5070`.
Its adjacent `.dmg.json` records the source commit above and lockfile SHA-256
`a833b582bb509701a269de4487957b706bb7a71b70ee08b1aa881a38ede19cab`.
These are git-ignored local outputs, not public downloads. This source identity
predates the documentation-only commit that adds this record; these results
don't claim verification of a later integration or published release.

The Swift suite includes editor/annotation/export tests and screenshot
completion tests for copy, actual file saving, save-and-copy, and failed-save
clipboard fallback. These establish tested app logic, not live screen capture,
system clipboard pasting into another app, or installed-app permission behavior.

## Permission and restart evidence from source

The following describes implementation inspection, not manual observations:

| Area | Source-backed behavior | Still unverified |
|---|---|---|
| Screen Recording | [`AppDelegate.applicationDidFinishLaunching`](../Sources/Vishot/AppDelegate.swift) calls `CGPreflightScreenCaptureAccess`, then `CGRequestScreenCaptureAccess` when access is absent. It doesn't relaunch the app. | Exact system prompt, successful access after approval, and whether quitting/reopening is required on each tested OS. |
| Accessibility | [`OverlayController.startHints`](../Sources/Vishot/Overlay.swift) checks trust when entering hints with `f`. [`ElementCatalog.isTrusted`](../Sources/Vishot/ElementCatalog.swift) prompts once per session, then checks trust again on later calls. | Prompt wording, access taking effect, and any required restart after approval. |
| Window raising | [`WindowRaiser.raise`](../Sources/Vishot/WindowRaiser.swift) returns without raising when Accessibility trust is absent. | Installed-app behavior with access disabled and enabled. |
| Launch and quit | [`main.swift`](../Sources/Vishot/main.swift) uses accessory activation; the bundle has `LSUIElement=true`. AppDelegate creates a menu-bar item and **Quit Vishot**. | First launch from a browser-quarantined installation. |
| Updates | [`build.sh`](../scripts/build.sh) uses the chosen signing identity; package checks require explicit ad-hoc signing. No automated update/permission migration is established by these checks. | Permission retention, repeated Gatekeeper approval, and restart requirements when replacing a different ad-hoc-signed version. |

The README therefore tells you to follow macOS quit-and-reopen prompts and
explicitly leaves update retention unresolved. It doesn't claim that either
permission is always retained or that a restart is always or never needed.

## Required live verification

All rows below are launch blockers, not completed tests. This session had no
native GUI-control tools and no Intel or macOS 14 host. The user's installed
app, permissions, and running processes weren't changed. No browser-downloaded
quarantined package was available or exercised.

| Coverage | First install | Replacement of an older version |
|---|---|---|
| Apple Silicon, supported macOS | Blocked: browser/quarantine and native GUI checks not performed. | Blocked: approval retention and restart behavior not observed. |
| Intel, supported macOS | Blocked: native hardware/session unavailable. | Blocked: native hardware/session unavailable. |
| macOS 14, on supported hardware | Blocked: macOS 14 environment unavailable. | Blocked: macOS 14 environment unavailable. |

Use the same exact release source and corresponding architecture packages for
these checks. Cover both processors and include macOS 14; record the processor
for each OS run. Don't remove quarantine to make a failing test pass.

1. Record the OS/build, processor, browser, candidate version, full source
   commit, DMG filename, and SHA-256. For replacement, also record the older
   app's version, source/signature identity, install path, and initial approval
   state. Use two genuinely different builds, not a reinstall of identical
   bytes.
2. Download the package through a browser and record evidence of its quarantine
   state. Follow the README to drag-install, eject, and launch from
   Applications. Record the actual launch warning, per-app **Open Anyway**
   path, and whether another approval is requested on replacement.
3. Record the initial Screen Recording state, prompt, and result immediately
   after enabling it. If macOS requests quitting/reopening, record the wording,
   do so, and record the result. Establish the actual restart requirement
   rather than inferring it from the API call or the signature check.
4. Take a window screenshot with the default shortcut and paste it into an
   image-capable app. Also check display and region targets. With Accessibility
   off, check basic capture; then press `f`, grant Accessibility, record any
   restart prompt, retry hints, and check window raising.
5. Add an arrow, rectangle, and text; copy and paste the annotated result.
   Check `s`, `S`, and **Save As**; open the PNGs and confirm the annotations
   and selected area match the pasted output.
6. Quit Vishot and replace it from the newer browser-downloaded DMG. Repeat
   launch, permissions, capture, annotations, copy, and save. Record each
   approval's actual state before and after replacement and any required
   restart. Don't assume a stable local development signature predicts the
   ad-hoc distribution result.
7. Attach the observed results and evidence, resolve discrepancies in the
   README/site FAQ, and link the final candidate identity before treating
   installation as publicly ready.

This record documents the installation verification boundary only. Publication,
public download access, and the Homebrew path need their own readiness checks.
