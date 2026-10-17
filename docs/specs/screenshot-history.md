# Screenshot history

Capture history retains editable screenshots after copying or saving, so you can
yank them again, find them by text or app, and continue editing. CleanShot X's
Capture History is the reference for the thumbnail browser, adapted to Vishot's
visual style and Vim-inspired commands. The associated issue is `vishot-qa7`.

The user confirmed the shared capture/editor model and delivery stages. Its
prerequisite is [Frozen capture editor](frozen-capture-editor.md), delivered in
stages before History. Its confirmed controls use Tab-selected corners and
hjkl/arrow movement.
Separate isolated window images and window-layout metadata are not part
of the design: each screenshot has one frozen full-display source and a crop.
Plain Return copies the selected crop from that visible-display source,
including overlapping windows. This capture behavior is the same with History
enabled or Off; Off changes persistence only.

## Scope

This feature provides a persistent local history with:

- A horizontal thumbnail strip using Vishot's palette, fonts, pixel borders,
  and HUD conventions.
- Yank, delete, reopen for editing, and text search.
- Original images, committed annotations and crop, and restored undo history.
- Background OCR and search over visible image text and captured metadata.
- Configurable global access and time-based retention.

Recording, imports, cloud sync, semantic image recognition, screen pinning,
drag-out, revision browsing, and annotation-selection tools are outside this
feature. Standalone save and clear-all shortcuts are not required in the
browser; saving remains available in the reopened editor, and Clear History is
an explicit Settings action.

## Entry lifecycle

A new entry is created when a screenshot is copied or successfully saved. Merely
capturing an image or discarding the editor does not create an entry. All target
kinds participate: window, element, display, and region.

Copy-and-save creates one entry. A failed save that falls back to the clipboard
also creates one entry. Canceling Save As does not create or update an entry.
Re-yanking an unchanged entry does not create a duplicate or renew its expiry.

Reopening an entry creates an editing session with its committed document and
undo stack. Finishing through copy or save updates the same entry. Discarding
returns to its prior committed state. A changed document renews retention and
moves the entry to the front; an unchanged output does neither. Do not change
the entry's identity or original capture time.

Store the frozen full-display image at full resolution, pixels-per-point scale,
annotations, the selected crop, and undo snapshots. Thumbnails and output include
only the selected crop. The reopened editor shows the whole frozen display with
the surroundings dimmed, just like editing a new capture. Restore undo in its
original order.
Do not persist redo: edits undone before the document is committed cannot be
redone after reopening. Boundary adjustment can reveal source pixels outside the
initial crop without requiring an earlier undo snapshot.

## Browser and session behavior

The browser opens from a **Capture History** menu item or a separately
configurable global shortcut, **unassigned by default**. Settings lets you
assign or clear it; menu access is always available. Settings and
`config.toml` use the existing shortcut validation and last-good application
rules. A registration conflict remains visible, with menu access available.

Show the browser on the display containing the pointer when opened. Use a
focused overlay presentation: dim the display, show a large preview of the
selected capture, and place the horizontal thumbnail strip and visible key
guide below it. The underlying app does not receive browser input.
Select the newest entry initially, retain chronological order outside search, and load
thumbnails as needed. Show the selected entry's app or target name and date in
the HUD. Empty history has an explicit empty state and can be closed normally.

Use the following physical-key commands in browsing mode:

| Key | Action |
| --- | --- |
| `h` / Left | Select the previous thumbnail. |
| `l` / Right | Select the next thumbnail. |
| `y` | Yank the selected result and close the browser. |
| `e` | Reopen the selected editable screenshot. |
| `/` | Enter text-search mode. |
| `d` | Delete the selected entry. |
| `u` | Undo the most recent deletion in this browser session. |
| Escape | Close the browser. |

Navigation stops at the ends rather than wrapping. Repeated key-down events
do not delete additional entries when `d` is held.
Mouse clicks select thumbnails, and horizontal scrolling browses the strip.
Keep the relevant key guide visible. Match command keys by physical key code,
as in the picker and editor.

In search mode, printable characters edit the query, including `y`, `e`, and
`d`; they do not run browser commands. Left/Right navigate matches and Backspace
edits the query. Enter accepts the selected match and returns to browsing with
that entry selected in the chronological strip. Escape leaves search and clears
the query. An empty query shows chronological results; no matches is explicit.
Text input uses the current keyboard layout.

Finishing or discarding an edit opened from History returns to the browser with
that entry selected. A changed entry is now first. Canceling Save As returns to
the intact editor. Loading a historical image must not depend on the old window,
screen position, or display still existing: place and fit it on the active
display, while preserving native image coordinates and export resolution.

Picker, editor, and browser share one session owner. Opening History during an
active picker/editor session is ignored rather than discarding work. Starting
a new capture from the browser closes the browser and begins the normal picker.
Settings changes activate between sessions, following the existing convention.

## Search

Search runs locally over background-indexed data. It matches contiguous text in:

- Text recognized from the committed visible image, including its crop.
- The captured app name and window title when available.
- Annotation text visible in the committed crop.

Capture metadata from the existing target/catalog data; do not introduce AX work
into capture startup. Display and region captures use their target names and
OCR, without attempting to identify every app visible within them.

Render the current visible document without a watermark for OCR. Hidden original
pixels and off-crop annotation text must not cause search matches. Reindex when
the committed visible document changes. Each OCR result belongs to a particular
entry revision; stale results cannot overwrite a newer revision or resurrect a
deleted entry. Persist the recognized text for reuse across restarts.

Queries ignore case and accents. Every whitespace-separated term must match a
contiguous part of an indexed field; scattered letters across words or lines do
not match. Exact fields rank above word starts, then other substring matches,
breaking ties by recency. A query's terms may match different indexed fields.
Use a deterministic local matcher;
no network calls, semantic models, or OCR per keystroke. Establish the exact
scoring with meaningful examples during implementation.

New entries are immediately browsable and searchable by available metadata while
OCR is pending. Show indexing status and refresh search results when OCR
completes. OCR failure leaves the entry usable and metadata-searchable; retry
unindexed entries on a later launch. OCR never delays clipboard delivery.

## Retention and deletion

Retention defaults to **7 days**. Settings and `config.toml` offer **Off**,
**1 day**, **3 days**, **7 days**, and **30 days**. Entries survive app restart.
Expiry uses entry creation time or the most recent completed changed edit,
whichever is later. Copying or saving an unchanged entry does not renew it.
Retention is age-based only, with no size-based eviction or recording budget.
Show History's disk usage in Settings.

The enabled retention interval applies to existing entries. Shortening it makes
older entries eligible for cleanup. Perform cleanup on launch and periodically,
and refresh browser contents without blocking input. Hold an entry open in an
editing session until that session ends; canceled editing does not renew it.

Off stops creating new entries. Existing entries remain browsable and expire
under the last enabled interval, persisted across restart. Existing entries can
still be edited; completing a changed edit renews them under that interval.
Re-enabling applies the selected interval. Disabling is not a clear operation.

`d` removes an entry from browsing and search immediately. Keep its data
recoverable for `u` until the browser session ends; repeated `u` can restore
deletions in reverse order. Browser-to-editor-to-browser is the same session.
Closing the session finalizes pending deletions. Interrupted sessions may
finalize these deletions on next launch; session-local undo is not promised
across restart.

**Clear History** in Settings asks for confirmation and removes all retained
entries. It is unavailable during an active capture/history/editor session.
It does not provide the browser's session-local undo. Delete, expiry, and Clear
History affect only private History data, never exported PNG files.

## Output preferences

Each yank or save uses the current active watermark preference, snapshotted at
the output action as today. Changing Settings therefore changes later output
from an old entry. Store and edit unwatermarked originals; do not bake the
watermark into document pixels or search thumbnails. Existing small-image
watermark omission and Retina DPI tagging continue to apply.

## Persistence and boundaries

Use a private folder per entry under
`~/Library/Application Support/Vishot/History`. Each entry has a stable unique
identity, original PNG, versioned structured document/undo metadata, a thumbnail,
and persisted search data. JSON is the default structured representation.
Retain the original capture time and the latest committed changed-edit time.
Original screen geometry is not required for restoration.

Publish complete entries and updates atomically, using staged files or
revision-specific files with an atomic committed metadata switch. A crash must
not replace a usable committed document with a half-written update. Clean up
uncommitted temporary data on a later launch. Ignore unsupported schema versions
without deleting them. Isolate malformed entries and surface a useful error;
one damaged entry must not prevent browsing others.

Separate these responsibilities behind small interfaces:

- The history store handles identity, atomic persistence, retention, and deletion.
- The search index handles revision-aware OCR scheduling and fuzzy matching.
- The browser controller handles selection, search input, and reuse commands.
- The session owner coordinates picker, browser, editor, and clipboard output.

History encoding, file writes, thumbnail preparation, and OCR run in the
background. The existing lazy clipboard provider must remain independent from
mutable document state. Do not share its lazily prepared output unsafely across
clipboard callbacks and history worker queues.

Copy or export succeeds independently of history persistence. If a history write
fails, report that failure through a persistent menu/Settings status without
blocking the successful output or claiming the entry was saved. Keep the last
valid committed entry after an update failure. Serialize writes and bound
background processing rather than spawning unbounded OCR/encoding jobs.

## Verification

Use unit and store integration tests for the behavior that does not require
desktop interaction:

- Round-trip original pixels, scale, annotations, crop, and undo order.
- Undo restored edits and recover pixels excluded by a crop; redo starts empty.
- Create once for copy/save combinations and fallback, and update rather than
  duplicate an existing entry.
- Survive restart, preserve the last committed update on failure, and isolate
  damaged or unsupported entries.
- Expire by the agreed timestamp, renew changed edits only, apply retention
  changes, and preserve the last enabled interval while Off.
- Delete/undo multiple entries and keep external exports untouched.
- Rank representative text queries, combine field matches, ignore hidden text,
  and reject stale OCR results after edits or deletion.
- Extend configuration tests for retention and the history shortcut, including
  conflicts and last-good settings behavior.

Run `swift test`. Manually verify the signed installed app's keyboard and mouse
browser flow, non-Latin command layouts and search typing, OCR on representative
screenshots, clipboard/export watermark behavior, editor return flow, multiple
displays, canceled Save As, permission failures, and capture responsiveness while
history encoding or OCR is running.

## Reference

The [CleanShot research note](../research/cleanshot-capture-history.md) distinguishes
documented reference behavior from unverified details. The lifecycle, Vim keys,
search, storage, and defaults here are Vishot decisions, not claims about
CleanShot's implementation.
