---
type: architecture
description: excerpt's architecture of record — modules, the capture document and file model, the cut tool, capture and scrolling capture, the editor and exports.
links:
  - rel: part-of
    to: CLAUDE.md
---

# excerpt — design

A macOS menu-bar screenshot tool: area / window / fullscreen / scrolling / text capture, a
floating preview, an annotation editor, and the **cut tool** — removing a band from the middle
of a screenshot and marking the join with a torn seam, so a long sheet or page shows its header
and footer without its body. Captures are routinely read by Claude, so tall output is exported
in a shape Claude can read.

## Modules

SwiftPM only — no `.xcodeproj`. macOS 15+. `ExcerptCore` builds in Swift 6 language mode; the
AppKit / ScreenCaptureKit targets build in Swift 5 mode (see `Package.swift`).

| Module | Owns | Depends on |
|---|---|---|
| `ExcerptCore` | The capture document (original image, cuts, annotations) as values; the pure algorithms — render, cut geometry, the original→rendered coordinate map, stitching, gap detection, tiling | CoreGraphics, ImageIO |
| `ExcerptCapture` | ScreenCaptureKit capture, the multi-display selection overlay, the auto-scroll driver that feeds frames to Core's stitcher, the hotkey bindings and the rules that judge a rebinding | Core |
| `ExcerptEditor` | Canvas, tools, undo; edits Core's document | Core |
| `ExcerptExport` | Vision OCR, the For Claude bundle (tiles + `text.md`) and the `excerpt read` command, with no UI | Core, Vision |
| `Excerpt` (app) | Menu bar, hotkey registration, preview thumbnail, settings, export UI, file I/O; runs `excerpt read` before AppKit starts | all |

The hard logic lives in Core as pure functions over values, so it is tested without UI or
permissions. **One renderer:** the editor canvas draws through Core's renderer, so what the
editor shows is byte-for-byte what export writes.

## Files

Captures land in the **library** — `~/Documents/Screenshots/` by default (a setting) — named
`Excerpt 2026-10-10 at 09.43.29.png` (the prefix is a setting; no `@2x` suffix).

- **The dated file is the primary**: the flattened render, carrying no metadata beyond standard
  PNG fields. It is what gets copied, dragged and shared, so it must never contain pixels the
  user removed — an embedded original would hand every recipient the unredacted capture.
- **`… original.png` is the private master**, written the first time a capture is edited. Its
  pixels are the untouched capture; the edit document (`excerpt.edits`, JSON) lives in a PNG
  `iTXt` chunk, the only part a re-save rewrites unless the primary was changed elsewhere
  (below). An unedited capture is one file.
- **Re-editing** the master loads the original plus its edits. The primary loads them too only
  while re-rendering them reproduces it pixel for pixel; a primary changed elsewhere (a
  redaction drawn over it) opens as a flat image, and saving it makes it the master's new
  original, so nothing it covers comes back. A primary whose original is gone opens flat.
  Saving re-renders the primary.
- Sidecar files and a separate edits database are both wrong here: library files get moved and
  sorted by other tools, which would orphan either one. The edits travel inside the master.
- **The top level holds the last 30 days; older files sit in `YYYY/MM-Month/`** (by creation
  date), so the folder opens on recent captures and Recent Captures, which reads only the top
  level, always has them. `LibraryFiler` does the filing (rules in its docblock) at launch,
  daily, and when switched on; it is a setting, on by default.
- "For Claude" output is scratch, not library content: `~/Library/Caches/excerpt/claude/<capture
  name>-<hash>/` (spaces become `-`, so `@` references hold; the hash is of the primary's path,
  so same-named captures in different folders keep separate bundles), replaced on each export
  and pruned once `ClaudeCache.maximumAge` (7 days) old: on every export, at launch and daily.

## The cut tool

**Model.** A cut is an axis plus a half-open range in original pixels. A *horizontal* cut
removes rows (the image gets shorter); a *vertical* cut removes columns (narrower). Up to
`EditDocument.maximumCutsPerAxis` of each: at that many the cut tool makes none on that axis and
says so. Overlapping or touching same-axis cuts merge. Rows are removed before columns, so every
tear spans the full remaining extent. Annotations are stored in original coordinates and placed
through one coordinate map (original → rendered); an annotation wholly inside a removed band is
not drawn, and the editor reports it ("1 annotation hidden by a cut").

**Interaction.** Tool key `C`. Drag across the image; the drag's dominant direction picks the
axis. The band is shaded while dragging and collapses with an animation into a seam on release.
Band edges **snap to gaps** — the nearest uniform pixel row/column (whitespace or a gridline)
within ~12pt — so a cut never bisects a line of text or a table row; `⌥` disables snapping.
Selecting a seam shows a handle per side; dragging one reveals or hides content on that side.
`Delete` removes the cut.

**The seam.** Both edges get a jagged torn edge with a soft shadow, separated by an ~18pt gap in
a neutral fill holding a pill: `⋯ 1,240 px hidden`, in points (rotated 90° on vertical cuts).
The tear's shape is seeded from the cut's position, so identical edits render identical pixels.

## Capture

| Default hotkey | Mode |
|---|---|
| ⌘⇧3 | Window |
| ⌘⇧4 | Area |
| ⌘⇧5 | Capture text (OCR → clipboard, no file) |
| ⌘⇧6 | All-in-one selector (area / window / fullscreen / scrolling / text) |

Hotkeys use Carbon `RegisterEventHotKey` (no permission, no dependency) and are all rebindable
in Settings, which refuses a combination another action holds, one of the editor's shortcuts or
an app-wide one such as ⌘Q, or one without ⌘, ⌃ or ⌥ unless it is an F-key. A binding Carbon
reports as taken, or that an enabled macOS shortcut holds, is flagged in the menu and Settings,
never failed silently. The Touch Bar screenshot shortcuts (⌘⇧6, ⌃⌘⇧6) are never counted as
holding one.

- **Area:** the screen freezes when selection starts (a still of every display is taken first,
  and the selection is cut from it), so hover states and open menus survive. Crosshair, loupe,
  W×H readout; `Space` moves the selection, `Esc` cancels.
- **Window:** hover-highlight, click; placed on a padded backdrop, its display's wallpaper with a soft
  shadow under the window, or a colour (all settings).
- **Fullscreen:** the display under the cursor.
- **Text:** select an area on the frozen screen; its text is copied in reading order and no file
  is saved. A note gives the line count, or says no text was found and leaves the clipboard
  alone.
- **All-in-one selector:** a menu of the five modes at the pointer, each showing its hotkey,
  shown once the stills are taken; the mode picked runs on them.
- Stills exclude desktop icons and excerpt's own windows through the `SCContentFilter`.
- **After every capture that makes a file** it is saved, copied to the clipboard, and shown as
  a large thumbnail (Edit · For Claude · Close, draggable) that closes after 15s (paused
  while the pointer is over it), or on drag-out. Shutter sound on. With *Show thumbnail at the
  pointer* on, it first appears centred on the pointer with no timeout, and docks in the corner
  once the pointer strays past `PointerPlacement.safetyMargin` of it (or the next capture lands).

### Scrolling capture (vertical)

1. Select the scrolling region, then press `Return` to auto-scroll, or scroll the region
   yourself to start with you scrolling: the overlay takes that first wheel event and stays up
   until the first frame, so the page hasn't moved when it is taken. The overlay opens on the
   last scrolling region of this launch, already waiting, so the same area can be captured
   again.
2. The Start button and the HUD (Done, Cancel) sit centred in the region when it is tall enough
   to leave `ScrollChromeLayout.scrollBand` clear above and below them, else just outside it.
   **Auto-scroll** posts scroll-wheel events in the region's taller part clear of the HUD, ~60%
   of its height per step, then waits up to `ScrollCapture.responseTime` for the page to answer
   (a caret blink isn't an answer) and for the frame to settle (two identical `SCStream` frames,
   or ~300ms).
3. **Stitching** (Core): frames reduce to row signatures; the offset from the previous frame is
   the one with the highest share of matching evidence rows (unique, non-uniform) in the overlap,
   clearly ahead of the others. **Sticky regions** — top/bottom rows unchanged while the rows
   between them move — are kept once: the header from the first frame, the footer from the last.
   **Side panels**: when the changed columns don't move as one (sticky panels still pinning,
   split panes), the widest run of column strips that does, at least
   `StitchMatcher.minimumBandShare` of the width, is the scrolling band, provided what changed
   on each side of it moved by an offset of its own (an animation there halts). Columns that didn't move
   with the band take their commonest colour in appended rows, so a panel shows once, from the
   first frame, with the background running on under it.
4. Stops on two consecutive no-movement steps, on `Return`, or at a maximum height (30,000
   image pixels; the stitch is truncated contiguously there).
5. **Manual fallback** when steps produce no movement before the page has moved, Accessibility is
   not granted, the pointer left the region or rests on the HUD, the wheel event failed, or the
   page scrolled a different distance than asked: the HUD reads "Scroll the page yourself · Return when done" and frames
   are sampled and stitched as the user scrolls, skipping any that don't match. A wheel event
   over the region that Excerpt didn't post (its own carry `EventScroller.marker`) hands
   scrolling to the user the same way, during an auto run or after an uncertain stop.
6. A live preview of the stitch sits beside the region.
7. An **uncertain stitch** (no offset clears the confidence threshold — video, animation) stops,
   keeping the stitch for `Return`; it never fabricates a seam. The HUD says where it stopped.
   In manual mode a mismatched frame is skipped and the HUD asks to scroll back. In auto mode an
   uncertain stitch halts, and in either mode the cap does: `Return` saves what is stitched,
   `Esc` discards, and after an uncertain stop scrolling the page yourself carries on from where
   the stitch ends. A stream failure or display change saves what is stitched and says so.

Known limits: a run of content identical except a narrow patch, flung past in manual mode, can
stitch at a wrong offset (auto mode checks each step's travel); a final short step that aliases
can be believed when the page ends next; any animation wider than a quarter of the scrolled
span, or several on the same rows, halts the capture; a sticky header with a changing top edge
(progress bar, clock) reads as content and halts, as can a sticky footer that unsticks into
the page's flow; the stream excludes only excerpt's windows, so desktop icons under the region
appear in it; the matcher ignores the right-edge scroll-bar strip but the stitch copies it (page
content can reach the edge), so an overlay scroll bar's thumb can appear along the right edge (select the region
without the scroll bar to avoid it).

Permissions are requested on first use, per feature: Screen Recording for any capture,
Accessibility for auto-scroll only.

## Editor

Opens from the thumbnail's Edit, from the menu bar's Recent Captures (the library's newest
`StatusMenu.recentLimit` PNGs by creation date, masters left out, then Open Capture… for any
other), or by opening a capture (registered as an Open With handler for PNG, not the default). Fits to width; tall captures scroll. Floats above other windows; no
Dock icon.

Tools: `V` select · `A` arrow · `R` rectangle · `P` path · `T` text · `N` step · `H` highlight ·
`B` blur · `K` crop · `C` cut. A new editor starts on the arrow. A drawing tool pressed on an annotation it
draws selects and moves it rather than drawing over it; other kinds are drawn over. The arrow drag
**starts at the head**. Crop snaps using the same gap detection as cuts.

**The item bar** floats above whatever is selected (below it when there is no room, kept on the
canvas, hidden during a drag) and carries that item's options and nothing else: delete for every
item, and colour (six), size (three; one control sets stroke, text and step size) and the
kind's own options where they apply — text adds its background, a step adds Move earlier / Move
later (disabled at either end of the sequence), a path adds Closed (disabled under three points) and Fill (disabled while open). The options per kind are one pure mapping. The
crop under `K` gets a bar with delete. A new annotation takes the colour, size and text background
last chosen, remembered across launches, and stays selected after it is drawn so its bar is
showing.

**Text** is drawn either plain in its colour or on a **background**: a rounded pill in its colour
with the text in `Palette.contrastingInk` (black on yellow, white otherwise). New text starts
with the background on. Typing previews through Core's renderer on every keystroke — the text view
under it supplies only input, caret and selection, its own glyphs transparent — so what is typed
is what saves. Return commits; ⌥Return adds a line.

**Steps** (`N`): each click places a numbered circle in its colour, the number in
`Palette.contrastingInk`, ringed in white. The number is not stored: it is the step's rank among
the document's steps in annotation order, so steps always read 1…n, a delete closes the gap and
Move earlier / later reorder them.

**Paths** (`P`) are polylines and polygons — routes, boundaries, bent pointers — drawn opaque in
their colour and width with round joins and caps, no arrowheads. Each click adds a vertex, with a
rubber-band segment to the pointer. A press-drag that starts a path is a freehand stroke, finished
on release; within a path begun by a click, a press-drag adds a freehand run, so clicks and
freehand mix in one path. Freehand is simplified on release (Ramer–Douglas–Peucker, half a stroke
width) into ordinary vertices. Return, a double-click, a tool switch or any save, undo or close
finishes it; a click on the first vertex of three or more closes it; Escape drops the last
vertex, and the last one abandons the path, as delete does. The bar shows while it is built, so
colour and size apply to it. Under two vertices is discarded; a finished path is one undo step. A selected path shows its vertices as handles: drag one to reshape, ⌥-click a
vertex to delete it (a path keeps two; a closed one left with two opens), ⌥-click a segment to
insert one; a drag elsewhere on the path moves it. A closed path with **Fill** on is tinted first, with highlight's multiply at
`AnnotationRenderer.highlightOpacity`, then stroked. A path is hit within slop of a segment, or
inside it when filled, and is hidden by a cut only when all its vertices lie inside one removed
band, as an arrow is.

**Border** turns the border on and off, and its chevron drops down an on/off switch, the six
colours and three widths (2, 4, 8pt); it frames the render in a solid line drawn inside its edge,
so a capture pasted into an email stands apart from the message. Choosing a colour or width
turns it on, and the next editor, across launches, starts from the last one chosen.

**Blur is destructive**: pixelation over noise. Blur rects under 12pt apart are one group,
pixelated on one grid over the group's bounding box in blocks at least 12pt and at least half
that box's shorter side, filling only the rects. So text of any size spans at most about two
blocks across its height, however many strips or nested rects cover it, and the covered content
cannot be read from the primary; pixelation defeats reading, not candidate-matching of short
known strings. The noise is seeded from a per-document salt stored in the master. The editor
shows the true result.

**The edit document** holds the cuts, an optional crop, the annotations (arrow, rectangle, path,
text, step, highlight, blur), all in original pixels, an optional border, plus the blur salt, so
every edit stays adjustable from the master.
Render order: blur (from original pixels) → crop → cuts and their labels → annotations, placed
through the coordinate map → border. The canvas caches the render up to the cuts and draws annotations
over it through the same Core code, so a drag repaints only annotations; a cut, crop or blur
change re-renders the cache. Undo is a stack of document values.

`⌘S` (Save) re-renders the primary, writes or updates the master, copies the render and closes
the editor; with nothing unsaved it only copies and closes. For Claude saves the same way before
it exports, then closes. **Discard** closes at once, dropping unsaved edits; closing the window
any other way with unsaved edits asks.

## Export

- **Copy** — every capture is copied as it lands, and the editor's Save copies its render.
  **Drag** from the thumbnail or the editor's title bar.
- **For Claude** (`⌘⇧C`), shaped so Claude reads every tile unscaled:
  - tiles render at **1× (points)** — Retina doubles pixels without adding legible text;
  - a capture that fits is one image; taller ones split into tiles overlapping ~100px, so every
    line appears whole in some tile, each as tall as `Tiling.tileLength(width:)` allows: within
    the 2000px side limit Claude enforces once a conversation holds over 20 images, and within
    its visual-token budget;
  - `text.md` holds Vision OCR in reading order, panes on different backgrounds one after the
    other (`ReadingOrder.blocks`), each cut written in as `[⋯ 1,240 px hidden]`;
  - the clipboard receives `@<path>` references to every tile and `text.md`, then a space, so
    Claude Code's file picker closes on paste;
  - both come from the render, never the original, so a cut band never reaches Claude and a
    blurred area reaches it only as the blur's noised blocks, from which no text is read;
  - the editor exports the render of the edits it saves; the thumbnail exports the
    primary file as `excerpt read` takes it, so a primary changed since it was saved exports as
    its own pixels.
- **`excerpt read <image>`** — the same bundle for any image file, not only a capture, so a
  Claude session handed a large screenshot can read it. It runs headless in the app's binary,
  before any `NSApplication` starts; see [Install and release](#install-and-release) for when
  that binary is the command and when it is the app. It prints `text.md` to stdout and the tile
  paths to stderr, and needs no Screen Recording permission. A master gets its cut markers, and
  so does a primary while it is exactly its master's render; a primary changed elsewhere reads
  as its own pixels, so a redaction drawn over it holds. Any other file is treated as uncut,
  upright, with Retina scale read from its DPI metadata (anything outside 1×–3× reads as 1×). A
  file it can't use exits non-zero with the reason. Input limits derive from the largest capture
  Excerpt makes. Edits with over `EditDocument.maximumCutsPerAxis` cuts on one axis or
  `EditDocument.maximumAnnotations` annotations read as damaged, and a capture cut into over
  `CaptureText.maximumRegions` regions is refused before any is read.

  Known limits: `text.md` reads columns that share a background row by row; `@path` references
  assume a home folder without spaces; Vision can miss text on busy synthetic backgrounds. Tiles
  split on height only, so a capture over 2000pt wide reaches Claude downscaled.

## Install and release

A release is one asset, `Excerpt.zip`: the Developer ID–signed app, notarized and stapled,
cut by `just release NOTES.md` (`scripts/release.sh`) from a clean, pushed `dev` at `VERSION`.
`install.sh` downloads the latest one and refuses it, before anything in the install
directories changes, unless its signature verifies, its Team ID is `G9V8U6ZU5E` and Gatekeeper
accepts it as notarized. It then quits the user's running Excerpt, replaces
`/Applications/Excerpt.app`, links `/usr/local/bin/excerpt` to the app's binary and relaunches.
The binary reads its invoked path: only from inside an app bundle (`.app/Contents/MacOS/`), with
no arguments or a first argument starting `-` (AppKit's `-NS…`), is it the menu-bar app.
Anywhere else — the `excerpt` link under any spelling, `swift run` — it is always a command, so
a bare or mistyped call prints usage and exits 64. There is no in-app updater: re-running the
installer is the update.
