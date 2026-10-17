# CleanShot X Capture History research

CleanShot presents Capture History as a recent-capture recovery and reuse tool:
restore captures, filter by media type, delete entries, and reopen screenshots
for editing or screen pinning. Its published maximum retention is one month.
The strongest reference for Vishot is this recovery workflow; the sources do
not establish a complete storage, versioning, or keyboard interaction contract.
Sources: [feature description][features-history], [screenshot page][screenshots],
and [release notes][changelog].

Researched October 13, 2026, using primary sources only. The current changelog
lists 5.0.1, released September 18, 2026. Historical release notes establish
when capabilities appeared, not that every interaction remains identical in
5.0.1. Official marketing screenshots have no explicit app-version label.
[Source: changelog][changelog].

## Evidence and limits

This note distinguishes **documented facts** (official prose or release notes),
**visual observations** (official images and their visible UI text), and
**unknowns** (not established by the inspected evidence). A selected setting in
a promotional screenshot is not evidence of a factory default.

- Official consumer support material inspected: [FAQ][faq] and
  [contact page][contact]. They link email support, not a Capture History
  help article. The [public sitemap][sitemap] and [docs navigation][api] did
  not surface such an article. `/docs` and `/support` returned 404;
  `help.cleanshot.com` could not be fetched. This is a discovery limitation,
  not proof that no other official help exists.
- The [official 4.4][video44], [4.5][video45], and [4.7][video47] update videos
  are linked from the changelog. Web fetching exposed their titles, but no
  usable transcript or video frames. No behavior below is attributed to
  watching these videos, and no timestamps are invented.
- No installed-app behavior was tested. Search absence, deletion semantics,
  and persistence guarantees cannot be proved from marketing images.

## Documented facts

The following findings are supported by official text. Where the source speaks
about Quick Access Overlay rather than History, that distinction is explicit.

### Purpose, entry points, and navigation

The documented goal is to recover and reuse recent captures, with separate
commands for opening the browser and restoring the most recently closed file.

- **Recent-capture browser:** “Easily access and restore recent captures.”
  History debuted in 4.4 on August 30, 2022.
  [Sources: features][features-history], [4.4 release notes][changelog].
- **One-click restore:** “Restore recent screenshots in one click.” The same
  section says you can “find, restore, copy, or share” recent captures, but
  does not specify whether copy/share happen directly in History or after
  restoration. [Source: screenshots page][screenshots].
- **Automation entry:** `cleanshot://open-history` “Opens capture history” and
  requires 4.4 or later. This confirms an independent history-opening action.
  [Source: official docs, Open history][api-open].
- **Last-closed recovery:** `cleanshot://restore-recently-closed` “Restores the
  most recently closed file from history.” Separately, 3.4.1 describes
  **Restore Recently Closed File** in the CleanShot menu as bringing back a
  closed Quick Access Overlay; 3.5.1 adds a shortcut for that action.
  These establish closed-overlay recovery, not a precise rule for what
  **Restore** does to every media type in the History browser.
  [Sources: official docs][api-restore], [3.4.1/3.5.1 release notes][changelog].
- **Type filtering:** “filter by specific capture type”; 4.5 adds a “filter
  option to Capture History.” [Sources: features][features-history],
  [4.5 release notes][changelog]. Exact visible categories are recorded below.
- **Multiple restores:** 4.5 says, “It's now easier to restore multiple files
  from Capture History.” It does not describe modifier keys, multi-selection,
  or whether the browser stays open. [Source: 4.5 release notes][changelog].
- **Double-click editing:** 4.6 says, “Double-Click in Capture History will now
  open Annotate.” The text does not define the double-click action for videos
  or GIFs. [Source: 4.6 release notes][changelog].

### Actions and previews

History has confirmed restore, removal, editing, and screen-pinning actions.
Several other useful actions are documented for the adjacent Quick Access
Overlay rather than explicitly for the History browser.

| Action | Confirmed behavior and evidence | Boundary or unknown |
| --- | --- | --- |
| Restore | One-click screenshot restore; multiple-file restoration improved in 4.5. [Screenshots][screenshots]; [changelog][changelog]. | Browser dismissal and exact destination for all media types are unspecified. |
| Copy | History marketing says “copy, or share”; Quick Access explicitly supports copying. [Screenshots][screenshots]; [Quick Access][features-quickaccess]. | A direct History copy button/shortcut is not established. |
| Save | Quick Access: “Instantly save, copy or drag & drop the files to other apps.” [Features][features-quickaccess]. | Direct saving/export from History is not documented in the inspected text. |
| Edit | 4.5.1 adds “open Annotate”; 4.6 makes double-click open Annotate. [Changelog][changelog]. | Exact context-menu location and historical annotation-state preservation are unspecified. |
| Drag | Drag-and-drop to other apps is documented for Quick Access. [Features][features-quickaccess]. | Dragging directly out of History is unconfirmed. |
| Delete | 4.5: “You can now remove files from Capture History”; current features also confirms deletion. [Changelog][changelog]; [features][features-history]. | Whether deletion touches exported files, moves anything to Trash, or supports undo is unknown. |
| Clear all | 4.5.1: “Added option to clear Capture History.” [Changelog][changelog]. | Control location, confirmation, and treatment of open/pinned/exported media are unknown. |
| Pin | 4.5.1 adds the option to “pin screenshots from Capture History.” Floating screenshots remain above windows, with size/opacity controls. [Changelog][changelog]; [features][features-floating]. | This is **pin to screen**, not evidence of a favorite or retention exemption. |
| Filter | Capture-type filtering is documented. [Features][features-history]. | Filter persistence and keyboard access are unknown. |
| Search | Cloud explicitly searches transcripts, screenshot content, and tags. [Cloud page][cloud]. | No inspected source establishes text, filename, OCR, or metadata search in local History. |
| Preview | Large thumbnails are visible in the official History image. [History image][history-image]. Quick Access Quick Look is documented: “pressing space on the overlay” in 1.1. [Changelog][changelog]. | Space-to-preview, full-resolution preview, and video playback **inside History** are unconfirmed. |

Quick Access has documented shortcuts: **⌘C** copy, **⌘S** save, **⌘W** close,
**⌘U** upload, and **⌘E** annotate, introduced in 4.1. These are not documented
as History shortcuts. In 4.8, holding Option while pressing Copy in Annotate or
Quick Access copies without closing the image.
[Source: 4.1/4.8 release notes][changelog].

### What enters history and what remains editable

Screenshots, recordings, and external files are supported categories, but the
published sources do not define an exhaustive insertion or versioning rule.

- **Screenshots and recordings:** “Never redo a screenshot or recording again.
  CleanShot keeps your recent captures close.” This explicitly covers both,
  without enumerating every capture mode or After Capture combination.
  [Source: screenshots page][screenshots].
- **External files:** 4.7 says, “Capture History will now include external files
  opened with CleanShot.” This is stronger than a screenshots-only model.
  It does not enumerate import routes or exceptions.
  [Source: 4.7 release notes][changelog].
- **Video and GIF context:** CleanShot documents MP4 and GIF recording, and its
  History image shows separate **Videos** and **GIFs** filters. The image
  supports those categories, not the full storage lifecycle of each format.
  [Sources: features, Screen recording][features], [History image][history-image].
- **Editable project format:** “Save editable CleanShot files so you can come
  back later and adjust annotations, redactions, and styling.” 4.0 introduces
  `.cleanshot` and states, “Reopened screenshots from the Quick Access Overlay
  are now editable.” Neither statement explicitly promises that every History
  entry retains all objects, crops, undo history, or project state.
  [Sources: screenshots page][screenshots], [4.0 release notes][changelog].
- **Reopen versus preserve:** Opening Annotate from History is confirmed;
  preserving its prior object model is not. Whether an edit updates one entry,
  creates another, retains an original, or records each export is unknown.
  The inspected 4.0, 4.5.1, 4.6, and 4.7 notes do not resolve that distinction.
  [Source: changelog][changelog].
- **Import routes exist:** Official docs separately describe opening a file in
  Annotate, opening a clipboard image, and adding a file-backed Quick Access
  Overlay. These are not an explicit guarantee that every route enters History.
  [Source: official docs][api].

### Retention, cleanup, and defaults

The sources establish time-based retention and manual cleanup, but no verified
factory retention value or persistence contract.

- **Published maximum:** “CleanShot can store up to 1 month of capture history.”
  4.7 adds a “1 month Capture History option.” One month is an available upper
  retention option, not a documented default.
  [Sources: features][features-history], [4.7 release notes][changelog].
- **History storage exists:** 4.4.1 fixes “storing files in Capture History for
  more than 1 day.” This establishes retention beyond one day was intended;
  it does not disclose storage location, format, or restart guarantees.
  [Source: 4.4.1 release notes][changelog].
- **Manual cleanup:** Remove individual files since 4.5; clear History since
  4.5.1. [Source: changelog][changelog].
- **Temporary-file cleanup is separate evidence:** 3.2, predating History,
  says “Automatically delete temporary files to save disk space.” It cannot
  establish the current History expiration scheduler or deletion mechanism.
  [Source: 3.2 release notes][changelog].
- **Defaults remain unknown:** History enabled/disabled on a fresh install,
  default retention, all interval choices, an Off/Never option, count/size
  ceilings, and automatic expiry timing are not specified in inspected prose.
  The setting shown in an official image is described separately below.

### Quick Access and cloud relationships

CleanShot documents an immediate capture overlay, recent-history recovery, and
optional hosted sharing as distinct capabilities.

- **Immediate workflow:** Quick Access is a “small pop-up in the corner” after
  a screenshot or video, for viewing, annotating, saving, copying, and dragging.
  It has configurable auto-close behavior and restoration of recently closed
  overlays. [Source: features, Quick Access Overlay][features-quickaccess].
- **Recovery link:** The menu's last-closed action brings back Quick Access;
  the current docs call its source “history.” This supports a recovery
  relationship without proving a one-to-one mapping between overlays and
  History entries. [Sources: 3.4.1 notes][changelog], [restore docs][api-restore].
- **Cloud is optional:** “using CleanShot Cloud isn't required to use the app
  or any other features.” History therefore does not require Cloud use.
  [Source: FAQ][faq]. This is not a cross-device synchronization guarantee.
- **Cloud upload is an action:** “Straight from the Quick Access Overlay,
  upload your screenshots or videos and get a link ready to share.”
  [Source: features, Cloud][features-cloud].
- **Cloud organization is documented separately:** “Find captures by
  transcripts, screenshot content and tags.” That claim belongs to Cloud;
  it does not establish equivalent local History search or tags.
  [Source: Cloud product page][cloud].
- **Unknown coupling:** Local expiry/deletion versus cloud deletion, uploaded
  badges/links in History, download-back behavior, and history synchronization
  are not established by these sources.

## Visual observations

These observations come from inspected first-party images linked on the live
site. They describe the pictured UI, not tested interactions or factory values.

- **History layout:** A wide, dark translucent panel over desktop wallpaper;
  a single horizontal row of large rounded thumbnails; partial neighbors at
  both sides; the central thumbnail outlined in blue with **Restore** beneath
  it. No sidebar, filename, timestamp, search field, or separate detail pane
  appears in this crop. The composition suggests horizontal browsing, but
  does not prove scrolling gestures, chronological order, or keyboard keys.
  [Official History image][history-image]; [homepage variant][home-history].
- **Filter labels:** **All**, **Screenshots**, **Videos**, and **GIFs** appear
  above the thumbnails; **All** is blue/selected in the image. This confirms
  visible choices, not the initial filter for a new installation.
  [Official History image][history-image].
- **Menu-bar entry and setting location:** **Advanced → Capture History →
  Keep history** shows **3 days**. Its UI help text says, “You can restore old
  files with 'Capture History' option from the menu bar.” This is first-party
  UI-text evidence of a menu-bar entry and a duration setting. **3 days is a
  pictured selection, not a verified default.** The dropdown is closed, so
  its full option list is unavailable. [Official Advanced image][advanced-image].
- **Shortcut configuration:** The Shortcuts image includes **Open Capture
  History** and **Restore Last Capture**, each showing **Record shortcut**.
  This supports configurable shortcut entry points; it does not establish a
  factory hotkey or that Last Capture has identical semantics to the separately
  documented last-closed command. [Official Shortcuts image][shortcuts-image].
- **Quick Access actions:** An official context-menu image shows **Open
  Annotation Tool…**, **Pin to the Screen**, **Upload to Cloud**, **Quick
  Look**, **Show in Finder**, **Open With**, **Open in Mail…**, **Temporarily
  Hide**, and **Close**, with **Copy** and **Save** buttons behind it. These
  controls belong to Quick Access, not the History thumbnail panel.
  [Official quick-actions image][quick-actions-image].
- **Overlay behavior controls:** Quick Access settings show auto-close action
  and interval controls, **Close after dragging**, **Close after uploading**,
  and **Save button behavior**. Help text describes Option to keep an item
  after dragging and to choose the save destination. These are configurable
  overlay behaviors, not evidence of History expiry or defaults.
  [Official Quick Access settings image][quickaccess-image].
- **After Capture is configurable:** A settings matrix separates screenshot
  and recording actions, including show overlay, copy, save, upload, annotate,
  screen pinning, and video editor. The matrix does not state which action
  combinations insert or omit History entries.
  [Official General settings image][aftercapture-image].

## Unknowns to resolve before copying behavior

The inspected sources leave these product decisions open. “Unknown” means
unverified, not absent from CleanShot.

1. **Entry and navigation:** Default hotkey; shortcut scope; arrows/Tab/Return/
   Escape behavior; initial selection; newest-first ordering; mouse wheel or
   swipe navigation; browser dismissal; full-screen versus window behavior;
   date grouping and labels; multi-selection mechanics.
2. **Preview and action placement:** History Quick Look or video playback;
   direct copy/save/drag/upload; menus and per-item buttons; behavior after
   restore; whether repeated restoration duplicates anything.
3. **Insertion and versioning:** Copy-only captures, auto-saved/uploaded media,
   canceled edits, discarded captures, OCR-only capture, clipboard imports,
   project imports, and combined images; original versus latest edited output;
   multiple variants; annotation/crop/undo-state preservation; Studio project
   retention versus exported recordings.
4. **Persistence and retention:** Survival across app quit, crash, reboot, and
   upgrade; backing directory; full-resolution storage; default and all
   retention choices; cleanup timing; time basis; count/byte ceilings; effects
   of shortening retention or disabling History.
5. **Deletion and pinning:** Trash versus permanent removal; undo/confirmation;
   deletion of exported originals; open-editor/overlay interactions; screen
   pins during expiry; any favorite or keep-forever mechanism.
6. **Search and cloud:** Local filename/OCR/metadata search; tags; History/cloud
   links or synchronization; whether local clear/delete affects cloud media.

For a later verification pass, the official [4.4 launch video][video44] and
[4.5 history-improvement video][video45] are the most targeted visual sources.
An installed-app walkthrough and a fresh settings profile would resolve
defaults and persistence more reliably than another marketing screenshot.

## Recommendations and interview options for Vishot

These are research-derived recommendations, **not agreed scope**. The questions
are ordered so later interface choices depend on a settled data lifecycle.

1. **Define the recovery promise first.** Choose all successful captures versus
   only completed copy/save outputs. Ask: “After copying a screenshot and
   replacing the clipboard, what exactly must History recover?” Include direct
   captures, edited captures, canceled editing, and failed-save fallback cases.
2. **Choose representation and editability.** Options: flattened output only;
   original plus final output; original plus editable document; or explicit
   versions. Ask: “Does reopening let you change existing annotations and
   recover cropped pixels, or only annotate the exported image?” CleanShot's
   open-editor action alone does not answer this.
3. **Specify retention independently of export.** Choose a bounded time window,
   count/byte policy, and explicit disable behavior. Ask: “What survives restart,
   when does it expire, and does Delete affect a saved PNG?” Do not inherit
   **3 days** as a claimed CleanShot default. Decide whether favorites exist;
   distinguish them from pin-to-screen.
4. **Choose the retrieval surface.** Options: a thumbnail strip like the official
   image, a grid for larger collections, or a keyboard list with a large preview.
   Ask: “How far back do you normally look, and what lets you recognize the
   right capture?” Decide menu/hotkey entry, selection, close behavior, and
   preview before adding filters or search.
5. **Prioritize reuse actions.** Consider copy, save, reopen editor, delete, and
   clear as explicit actions. Ask whether reuse acts directly from History or
   restores another UI first, and whether the browser stays open. Evaluate
   drag-out and screen pinning separately.
6. **Validate organization needs.** Type filters matter when multiple media
   types exist; alternatives for screenshots include dates or capture modes.
   Ask whether thumbnail browsing suffices or filename/OCR search is necessary.
   Treat imports and cloud as separate decisions rather than implicit parts of
   screenshot recovery.

## Primary source index

These links let you revisit the exact evidence. Changelog citations identify
the relevant version in the text because the page exposes no version anchors.

- [All features][features]: History, Quick Access, recording, pinning, and Cloud.
- [Screenshots][screenshots]: History purpose, one-click restore, and projects.
- [Changelog][changelog]: 3.4.1/3.5.1 recovery; 4.0 editability; 4.1 overlay keys;
  4.4 introduction; 4.4.1 retention fix; 4.5 deletion/filter/multiple restore;
  4.5.1 edit/pin/clear; 4.6 double-click; 4.7 imports/month retention.
- [Official docs][api]: Open History and restore-last-closed semantics.
- [FAQ][faq] and [Cloud product page][cloud]: optional Cloud and hosted search.
- [History screenshot][history-image], [Advanced settings][advanced-image], and
  [Shortcuts settings][shortcuts-image]: primary visual references.
- [Official 4.4 video][video44], [4.5 video][video45], and [4.7 video][video47]:
  discovered first-party video references; content was not inspected.

[features]: https://cleanshot.com/features
[features-history]: https://cleanshot.com/features#history
[features-quickaccess]: https://cleanshot.com/features#quickaccess
[features-floating]: https://cleanshot.com/features#floating
[features-cloud]: https://cleanshot.com/features#cloud
[screenshots]: https://cleanshot.com/screenshots
[changelog]: https://cleanshot.com/changelog
[api]: https://cleanshot.com/docs-api
[api-open]: https://cleanshot.com/docs-api#open-history
[api-restore]: https://cleanshot.com/docs-api#restore-recently-closed
[faq]: https://cleanshot.com/faq
[contact]: https://cleanshot.com/contact
[sitemap]: https://cleanshot.com/sitemap.xml
[cloud]: https://cleanshot.com/product/cloud
[history-image]: https://cleanshot.com/img/screenshots/history.png
[home-history]: https://cleanshot.com/img/home/more/history.png
[advanced-image]: https://cleanshot.com/img/features/settings12.png
[shortcuts-image]: https://cleanshot.com/img/features/settings3.png
[quick-actions-image]: https://cleanshot.com/img/features/quick_actions.png
[quickaccess-image]: https://cleanshot.com/img/features/settings4.png
[aftercapture-image]: https://cleanshot.com/img/features/settings2.png
[video44]: https://www.youtube.com/watch?v=FNHt4WUa13w
[video45]: https://www.youtube.com/watch?v=GOjV01brFQg
[video47]: https://www.youtube.com/watch?v=JyqCSh9m9oc
