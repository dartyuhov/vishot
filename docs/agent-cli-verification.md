# Signed agent CLI verification

Live verification on October 21, 2026 confirms covered-window capture,
connected-display capture, minimized rejection, background startup, and actual
image inspection on macOS 26.7.1 arm64. This is partial end-to-end evidence;
the remaining platform and interactive checks below are still open.

## Runtime and signing context

The test uses the combined, uncommitted discovery worktree based at `d4eb3e0`.
No application implementation files change during this verification.

- OS: macOS 26.7.1, build `25G241`, native `arm64`.
- Agent: OpenCode `1.19.0`, model `github-copilot/gpt-6.1-sol`.
- Bundle: `/Users/dartsiukhou/dev/personal/vishot-agent-cli-discovery/build/Vishot.app`.
- App and CLI version: `0.1.0`.
- Signature: `Apple Development: darst94@gmail.com (64X2U5P2AS)`,
  team `U45J3XS8FA`, hardened runtime. Deep strict verification passes.
- Build: the existing stable-signed build from the packaging slice, signed at
  10:37:23 local time. The test runs this isolated local bundle, not a newly
  published or quarantined installation in Applications.
- Capture authorization: the signed background app successfully captures;
  this session does not request or reset Screen Recording or Accessibility.
  `minimized_unsupported` also confirms positive minimized-state detection.
- The user's existing `/Users/dartsiukhou/Applications/Vishot.app`, PID `98540`,
  remains running. Tests never terminate that process or move its windows.

The bundled [capture skill](../skills/vishot-capture/SKILL.md) supplies the
discovery, exact-ID capture, immediate Read, and retention workflow. No external
skill installer, Node installation, or agent-folder modification runs.

## Retained local evidence

All raw fixture evidence remains in this absolute directory. It is outside
the repository and is not a portable or permanent release artifact:

```text
/private/var/folders/nr/0qk2bwcd7vxbk9wj6rc735wr0000gp/T/opencode/vishot-vk1-7
```

The directory contains `fixture.swift`, its signed `Fixture.app`, `report4.json`,
`run4-*.json`, `run4-*.stderr`, and retained `.vishot/` PNGs. Earlier reports
record fixture-placement attempts and are not multi-display evidence. Raw
reports include local window IDs and history hashes; they are not copied into
the public repository.

The principal covered-target PNG is:

```text
/private/var/folders/nr/0qk2bwcd7vxbk9wj6rc735wr0000gp/T/opencode/vishot-vk1-7/.vishot/window-14007-676248bd-a58d-4147-9b3a-453642ee8932.png
```

The confirmed second-display PNG is:

```text
/private/var/folders/nr/0qk2bwcd7vxbk9wj6rc735wr0000gp/T/opencode/vishot-vk1-7/.vishot/window-14010-98649752-f0a4-4ce4-b7e4-069344268dce.png
```

## Controlled fixture and commands

The temporary regular AppKit fixture creates only its own windows. It orders
them behind the user's windows without activating itself, minimizes its own
green target, and orders its red occluder above its blue target. Its final
second-display target is a normal-level, nonactivating borderless panel.
Fixture windows close when the fixture exits; captured files remain.

The retained source compiles and runs with these commands from the evidence
directory:

```sh
swiftc -swift-version 5 fixture.swift -o Fixture.app/Contents/MacOS/Fixture
codesign --force --sign "Apple Development" --options runtime Fixture.app
Fixture.app/Contents/MacOS/Fixture
```

The source invokes the actual bundle's `Contents/Helpers/vishot`, with the
evidence directory as its current directory. The final run issues:

```sh
vishot windows
vishot capture --window-id 14007
vishot capture --window-id 14008
vishot capture --window-id 14010
vishot capture --window-id 14009
vishot capture --window-id 4294967295
```

Those IDs belong to this run only. Reruns create fresh IDs, which the fixture
reads directly from its windows. The harness then opens the returned PNGs
through its built-in `functions.read` tool; it does not launch an image viewer.

Before the final run, only the earlier test-owned build process, PID `12305`,
receives `SIGTERM`. The first discovery request then launches the correct
local bundle through the CLI's background startup path. The final report shows
new build PID `23980` alongside the unchanged user installation PID `98540`.
Subsequent requests exercise the already-running service.

## Capture results

All six requests return JSON with empty stderr. Successful images decode with
ImageIO immediately after command exit; decoded dimensions match JSON.

| Request | Result | Duration | Image pixels |
| --- | --- | --- | --- |
| Background discovery | Exit 0; all four fixture IDs listed | 0.232 s | — |
| Covered blue target `14007` | Exit 0; exact requested ID | 0.265 s | 960 × 584 |
| Red occluder reference `14008` | Exit 0; exact requested ID | 0.178 s | 1000 × 624 |
| Second-display purple target `14010` | Exit 0; exact requested ID | 0.190 s | 880 × 544 |
| Minimized green target `14009` | Exit 8, `minimized_unsupported` | 0.169 s | No capture result |
| Stale ID `4294967295` | Exit 7, `target_unavailable` | 0.146 s | No capture result |

The red window's Cocoa frame `{{40,40},{500,312}}` fully contains the blue
window's `{{50,50},{480,292}}`. The ordered on-screen layer-0 list places red
`14008` ahead of blue `14007` throughout capture. Discovery still lists blue.
Other user windows can cover both; no window is raised to inspect it.

The connected displays are `YMG-4K27-01`, Cocoa frame
`{{0,0},{2304,1296}}`, and `Built-in Retina Display`, frame
`{{2304,329},{1496,967}}`. The final purple panel stays on the built-in display
at `{{2384,409},{440,272}}`; discovery reports CG bounds
`{x:2384,y:615,width:440,height:272}`. Earlier titled fixtures were relocated
to the primary display and do not establish multi-display support.

The minimized fixture reports `isMiniaturized == true` before and after every
request. Both failures contain no `capture` result and do not return another
target or older path. Prior successful PNGs remain retained.

## Desktop preservation evidence

The fixture samples every nominal 20 ms while each process runs and records
full snapshots before and after each request. These are observations with
finite sampling, not proof that no shorter transient can exist.

- Foreground application PID remains `1313` in all snapshots and all 32 final
  request samples. Neither fixture nor Vishot becomes foreground.
- Each request's complete ordered on-screen layer-0 window-ID array is
  identical before and after and across its samples. The cover remains above
  the target; user-window relative order does not change.
- Clipboard change count remains `573`. SHA-256 hashes for every materialized
  pasteboard item/type match, including PNG and TIFF data. Reading those data
  types can resolve an existing lazy provider, but does not replace contents.
- All 149 Capture history file paths and SHA-256 hashes match before and after
  each request. This includes metadata, originals, previews, thumbnails, and
  retention state. No CLI capture enters history.
- No visible Vishot windows appear in final snapshots or request samples,
  including nonzero window layers. No visible System Settings windows appear
  before or after. This observes no picker, editor, setup, or permission UI
  under the existing authorization/completion state; it is not a fresh-user
  authorization-denial test.
- Read-only temporary SkyLight queries report unchanged native current-Space
  IDs `4` and `284` on the two displays, before, during, and after all requests.
  The probe uses `SLSCopyManagedDisplaySpaces` only to observe current state;
  it never changes Spaces or uses that private API in application code.

## Actual visual inspection

OpenCode's built-in image-capable Read returns the PNGs as visible images in
this agent session. The agent visually checks the covered blue target, purple
second-display target, and red occluder reference, rather than inferring image
content from JSON or hashes.

The blue image contains the heading **COVERED TARGET — BLUE**, white fixture
text, and **7 × 6 = 42** on a blue background. The red occluder is absent. The
reference image is red and says **OCCLUDER — RED — MUST NOT APPEAR**. The purple
image says **SECOND DISPLAY — PURPLE** and **7 × 6 = 42**. No image contains a
Vishot watermark, editor annotations, visible cursor, or added drop-shadow
margin. The blue fixture's long date text clips at its own label boundary;
that is fixture layout, not overlap contamination.

## Automated and packaging context

This verification reruns only the relevant locked setup and installation
checks, since application code does not change:

```sh
swift test --force-resolved-versions \
  --filter 'AgentInstallationHostTests|CLISettingsTests|SetupTests|SetupWindowTests'
codesign --verify --deep --strict build/Vishot.app
build/Vishot.app/Contents/Helpers/vishot --version
git diff --check
```

All 23 selected tests pass, including actual compiled-CLI link/upgrade,
conflict/PATH, host skill copying, skip, later Settings installation,
permission rechecks, and first-capture handoff. Version returns `0.1.0`.

The earlier packaging slice records 230 full locked Swift tests, 13 package
tests, and 20 Homebrew checks passing on this same macOS/architecture. Its
mounted-DMG copy and isolated Homebrew app-artifact installation preserve
signing/layout and exercise bundle replacement through an unchanged symlink.
Those are local artifact checks, not a public tap download, receipt-driven
`brew upgrade`, quarantined DMG, or Gatekeeper walkthrough. See
[packaging](packaging.md) and [Homebrew](homebrew.md) for the existing gates.

## Remaining verification gaps

Keep the end-to-end ticket open until these checks are reviewed or completed:

- Native cross-Space target capture is untested. Current-Space invariance is
  observed, but no fixture is assigned to another native Space: doing so with
  available controls would risk switching the user's desktop. Offscreen
  placement and second-display capture are not cross-Space evidence.
- macOS 14 runtime and native Intel execution need suitable hosts. A macOS 14
  deployment target, ARM tests, or Intel metadata checks do not fill that gap.
- The signed app's ordinary interactive frozen-source picker/editor workflow
  needs a hands-on responsiveness check during concurrent CLI captures. This
  session preserves user focus instead of invoking the global picker.
- Setup/install/skip and later Settings behavior have passing actual AppKit
  host tests, but this session does not click through the signed app's setup,
  alter the user's installation link, reset setup completion, or revoke TCC.
- Fresh-user denied-permission/background-start UI behavior needs an isolated
  macOS account or permission context. Existing-authorized background launch
  passes; no missing-permission runtime claim is made.
- Public skill installation remains pending publication of the skill source.
  The external installer is never executed by this verification.
- Full public distribution/quarantine/upgrade checks remain as recorded in the
  packaging slice. This session does not publish or download a release.

No implementation changes, git commits, merges, pushes, PRs, or ticket closures
occur during this verification. Only the test-owned build instance is used
for background-start experiments; the user's installed instance is preserved.
