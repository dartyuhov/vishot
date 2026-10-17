# Frozen capture editor

This draft defines the editor prerequisite for
[Screenshot history](screenshot-history.md). Capture one full display, treat the
selected area as a crop, and let the user adjust that area after capture. The
user confirmed this model, delivery stages, and the corner-based controls below.

## Capture model

Each screenshot uses one frozen full-display image, excluding Vishot's own
overlay. The selected target supplies only the initial crop rectangle. The
image contains exactly what was visible on that display, including overlapping
windows. Do not retain separate isolated window images or window-layout data.

Retain only one display. Choose the display containing the largest portion of
the selected target, intersect the initial crop with it, and clamp later boundary
adjustments to that display. Display captures start with the whole image selected.

The picker remains live. Entering the editor captures and displays the frozen
source rather than live content. Plain Return keeps its existing direct-capture
behavior during this editor stage. The later History stage extends direct copies
to retain a full-display source and output only the selected crop, so those
entries can also expand when reopened.

## Presentation and adjustment

The editor shows the whole frozen display, with pixels outside the selected
rectangle dimmed. The selected rectangle is the editable area for drawing and
text and the area included in output. Exported images, History thumbnails, and
OCR search include only that selected area.

Rework the existing crop feature so the user can enlarge as well as shrink the
already selected rectangle within the same frozen image. For example, moving
the top boundary outward includes an additional element above the initial
selection. Provide keyboard controls consistent with Vishot and draggable crop
edges/corners. Drawing and text are confined to the selected area. There is no
separate source-reveal mode: surrounding source pixels are already visible under
the dim. There is no post-capture window or element selection, automatic layout
inference, or recapture during adjustment.

Annotations remain anchored in source-image coordinates when crop edges move.
Changing the crop is undoable. Export uses the current crop and current
annotations, preserving capture scale and resolution.

History reopens this same editor presentation and behavior: frozen display,
dimmed surroundings, selected rectangle, and annotations.

Replace the current draw-a-new-rectangle crop workflow with adjustment of the
existing selection. Press `c` to enter **Resize** with a corner highlighted.
`Tab` cycles the four corners; `Shift-Tab` reverses the order. `hjkl` or arrows
move the active corner horizontally or vertically, changing its adjacent
boundaries. Existing fine, normal, and fast movement apply. `c`, `Return`, or
`Escape` applies the new bounds and exits as one undoable adjustment. Undo then
restores the previous bounds; undo during adjustment cancels the preview.
Boundaries cannot
cross or create an empty selection. No-op adjustments create no undo step.

Mouse users can drag an edge or corner directly without first selecting Crop.
Hovering the outline indicates resizing; dragging inside the selected area
continues to use the current annotation tool. Each completed resize is one
undoable change.

## Delivery stages

Deliver the work in small stages, each independently verified:

1. **Frozen source:** replace pre-cropped editor inputs with a full-display
   image and initial crop; show dimmed surroundings and output only the crop.
2. **Boundary adjustment:** add keyboard crop adjustment and draggable boundaries
   on the frozen image, with undo and consistent annotation coordinates.
3. **History persistence:** retain and reopen that source, crop, annotations, and
   undo using the agreed lifecycle and retention policy.
4. **History browsing and search:** add the thumbnail strip, Vim commands, and
   background OCR index defined in the History design.

Further splitting can be decided when writing implementation tickets. This
document defines behavior and staging, not permission to start implementation.

## Verification

Verify capture/crop coordinate mapping at different Retina scales and display
origins, clamping to the selected display, and exact crop export. Verify that
expanding a crop reveals frozen pixels rather than current screen contents and
that annotations do not shift when boundaries move.

Check the signed installed app for frozen rendering, keyboard and mouse boundary
adjustment, undo, direct-copy output, overlay exclusion, and multi-display
selection. Confirm thumbnails and OCR never include unselected source pixels.
