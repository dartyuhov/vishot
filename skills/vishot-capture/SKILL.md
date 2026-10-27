---
name: vishot-capture
description: Inspect a running macOS app window with Vishot's native CLI and your built-in image reader. Use when asked to capture or visually inspect a desktop app, distinguish multiple windows, or inspect a covered window while preserving the user's focus.
compatibility: macOS 14 or newer, installed Vishot app with Screen Recording permission, terminal execution, and a built-in image-reading tool.
---

# Inspect a window with Vishot

Capture an exact live window into the current workspace, then open its PNG as
visual input. The native CLI needs no Node, Python, Swift, MCP server, or plugin.

## Discover, capture, read

Complete these steps for each requested inspection:

1. Run commands from the user's intended workspace so output belongs to that
   task. Use `vishot` from PATH. If unavailable, check `~/.local/bin/vishot`, or
   ask the user for the installed app location and use its
   `Contents/Helpers/vishot` executable. Quote paths containing spaces. Settings
   offers optional user-local CLI installation; don't install another runtime.
2. Run `vishot windows`. Require exit 0 and JSON `schemaVersion: 1, ok: true`.
   Select the exact `windows[].id` using `app.name`, `app.bundleID`, `app.pid`,
   `title`, and `bounds`. If multiple windows fit, ask which one. IDs describe
   live windows, not durable identities; rerun discovery after a stale-ID error.
3. Run `vishot capture --window-id <id>`, replacing `<id>` with the selected
   numeric ID. Require exit 0, `ok: true`, and a `capture` result containing
   `path`, `target`, `width`, and `height`. Confirm `capture.target.id` matches
   the request. Keep the exact returned absolute path for this task.
4. **Immediately open `capture.path` with your built-in image-reading tool.**
   For example, use OpenCode's image-capable Read tool, Claude Code's Read
   tool, or Codex's `view_image`, as available in the current harness. A path,
   dimensions, JSON, or base64 text is not visual inspection. If image input
   is unavailable or denied, report that you captured a file but could not
   inspect it; don't claim to have seen its content. Don't launch an external
   viewer as a substitute.
5. Answer from the image you actually opened. Capture and read a fresh image
   after relevant app changes; keep previous files unless cleanup is requested.

For example, if discovery identifies window 42:

```sh
vishot windows
vishot capture --window-id 42
```

A successful capture has this shape (values are illustrative):

```json
{"schemaVersion":1,"ok":true,"capture":{"path":"/workspace/.vishot/window-42-9ab68a91-631e-4497-b28b-c19a3f06692a.png","target":{"id":42,"app":{"pid":123,"bundleID":"com.example.Editor","name":"Editor"},"title":"Document","bounds":{"x":-800,"y":30,"width":800,"height":600}},"width":1600,"height":1200}}
```

`target.bounds` and discovery bounds use **points** in CoreGraphics global
coordinates: primary display top-left origin, y downward, possibly negative
x/y on other displays. Capture `width` and `height` are **image pixels**.
The file is complete and immediately readable before success is reported.
Concurrent commands create unique files under the caller's `.vishot/`.

## Supported states and desktop preservation

Vishot captures the window's own content, including fully covered windows and
windows on connected displays. It excludes overlapping apps, added shadow,
cursor, Watermark, and annotations. The signed app starts in the background
when needed; requests preserve focus, stacking, clipboard, and Capture history
and don't open the picker, editor, setup, or permission UI.

Minimized windows are unsupported and remain minimized. Native cross-Space
capture is best effort; never switch Spaces or raise, activate, move, or restore
a window to make an automated capture succeed. Ask the user to change its state
manually if needed. Offscreen coordinates alone don't establish native Space
support or prove minimization. Screen Recording authorization belongs to the
signed app; complete missing setup manually in Vishot. Accessibility is optional.

## Handle errors

Failures exit nonzero and return
`{"schemaVersion":1,"ok":false,"error":{"code":"target_unavailable","message":"..."}}`.
Read `error.code` and explain the actionable message. A failure has no usable
capture: don't substitute another window, an older file, or clipboard content.

| Exit | Code | Response |
| --- | --- | --- |
| 2 | `invalid_arguments` | Correct the command or ID; capture accepts windows only. |
| 3 | `permission_denied` | Ask the user to enable Vishot Screen Recording in System Settings and reopen Vishot manually. |
| 4 | `startup_failed` | Ask the user to check the installed app location and open Vishot manually. |
| 5 | `timeout` | Report the timeout; retry once if appropriate, without using any older output. |
| 6 | `service_failure` | Report the service failure; ask the user to reopen/update Vishot if it persists. |
| 7 | `target_unavailable` | Rediscover live windows; reselect by identity and ask if ambiguous. |
| 8 | `capture_unavailable` | Explain the window is unavailable; do not infer that it is minimized. |
| 8 | `minimized_unsupported` | Ask the user to restore the window manually if they want another capture. |
| 9 | `encoding_failed` | Report that no valid PNG was saved. |
| 10 | `output_write_failed` | Check the caller workspace permissions, free space, and `.vishot/` directory; no clipboard fallback exists. |

Both commands support `--startup-timeout <seconds>` and `--timeout <seconds>`
(5 seconds each by default, finite values from 0.05 through 60). A larger wait
is an explicit retry choice, not a reason to loop indefinitely. Captures are
bounded to 64 million pixels, 32768 per side, and 90 MiB of PNG bytes.

## Retention and explicit cleanup

Keep captures by default, including after the task finishes. Track the returned
absolute paths you created. Only when the user explicitly requests cleanup,
remove the intended files from that list with your file tool or an exact-path
command, quoting each path. Confirm the scope if the request is ambiguous.
Avoid wildcard deletion or recursive removal of `.vishot/`: another task or
concurrent caller may own other captures there. Report which files you removed.
