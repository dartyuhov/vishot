# Vishot

A keyboard-first macOS screenshot tool: pick something on screen with the keyboard, optionally mark it up, and copy or save it.

## Picking

**Target**:
The thing a mode selects for capture: a window, an element inside a window, a whole display, or a region.
_Avoid_: Selection (that is the act of picking one), item

**Target label**:
The name of the selected target (its app or display), shown on an accent tag in the target's top-left corner.
_Avoid_: Title, tab, caption, label

**Hint**:
The short letter code shown on an element of a window, typed to select that element. The hint is the code, not the element.
_Avoid_: Hint label, hint code, tag, label

## Editing

**Editable screenshot**:
A screenshot that retains its frozen source image, annotations, and crop as
separate parts, so edits can be undone and its selected area adjusted.
_Avoid_: Flattened image, export

**Frozen source**:
The full image of one display at capture time, from which a screenshot's selected
area is taken.
_Avoid_: Live screen, isolated window image

**Capture history**:
The collection of editable screenshots retained after copying or saving, for
later reuse and editing.
_Avoid_: Clipboard history, undo history

**Yank**:
Copy a screenshot's current result to the clipboard.
_Avoid_: Restore (when referring only to copying)

## Brand

**Wordmark**:
The name "vishot" in the pixel font's small capitals, the way the landing page sets it.
_Avoid_: Logotype, VISHOT (full-height capitals)

**Watermark**:
The optional "vishot.dev" badge in the corner of a copied or saved image,
crediting Vishot.
_Avoid_: Badge, signature, branding
