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
  a large thumbnail (Copy · Edit · For Claude · Close, draggable) that closes after 15s (paused
  while the pointer is over it), or on drag-out. Shutter sound on. With *Show thumbnail at the
  pointer* on, it first appears centred on the pointer with no timeout, and docks in the corner
  once the pointer strays past `PointerPlacement.safetyMargin` of it (or the next capture lands).

### Scrolling capture (vertical)

1. Select the scrolling region, press `Return`.
2. **Auto-scroll** posts scroll-wheel events at the region's centre, ~60% of its height per
   step, then waits for the frame to settle (two identical `SCStream` frames, or ~300ms).
3. **Stitching** (Core): frames reduce to row signatures; the offset from the previous frame is
   the one with the highest share of matching evidence rows (unique, non-uniform) in the overlap,
   clearly ahead of the others. **Sticky regions** — top/bottom rows unchanged while the rows
   between them move — are kept once: the header from the first frame, the footer from the last.
4. Stops on two consecutive no-movement steps, on `Return`, or at a maximum height (30,000
   image pixels; the stitch is truncated contiguously there).
5. **Manual fallback** when steps produce no movement before the page has moved, Accessibility is
   not granted, the pointer moved, the wheel event failed, or the page scrolled a different
   distance than asked: the HUD reads "Scroll the page yourself · Return when done" and frames
   are sampled and stitched as the user scrolls, skipping any that don't match.
6. A live preview of the stitch sits beside the region.
7. An **uncertain stitch** (no offset clears the confidence threshold — video, animation) stops,
   keeping the stitch for `Return`; it never fabricates a seam. The HUD says where it stopped.
   In manual mode a mismatched frame is skipped and the HUD asks to scroll back. In auto mode an
   uncertain stitch halts, and in either mode the cap does: `Return` saves what is stitched,
   `Esc` discards. A stream failure or display change saves what is stitched and says so.

Known limits: a run of content identical except a narrow patch, flung past in manual mode, can
stitch at a wrong offset (auto mode checks each step's travel); a final short step that aliases
can be believed when the page ends next; any animation wider than a quarter of the scrolled
span, or several on the same rows, halts the capture; a sticky header with a changing top edge
(progress bar, clock) reads as content and halts, as can a sticky footer that unsticks into
the page's flow; the stream excludes only excerpt's windows, so desktop icons under the region
appear in it; the matcher ignores the right-edge scroll-bar strip but the stitch copies whole
rows, so an overlay scroll bar's thumb can appear along the right edge (select the region
without the scroll bar to avoid it).

Permissions are requested on first use, per feature: Screen Recording for any capture,
Accessibility for auto-scroll only.

## Editor

Opens from the thumbnail's Edit, or by opening a capture (registered as an Open With handler
for PNG, not the default). Fits to width; tall captures scroll. Floats above other windows; no
Dock icon.

Tools: `V` select · `A` arrow · `R` rectangle · `T` text · `H` highlight · `B` blur · `K` crop ·
`C` cut. Six colours, three sizes (one control sets stroke and text). **Border** frames the
render in a solid grey line drawn inside its edge, so a capture pasted into an email stands
apart from the message. The arrow drag
**starts at the head**. Crop snaps using the same gap detection as cuts.

**Blur is destructive**: pixelation over noise. Blur rects under 12pt apart are one group,
pixelated on one grid over the group's bounding box in blocks at least 12pt and at least half
that box's shorter side, filling only the rects. So text of any size spans at most about two
blocks across its height, however many strips or nested rects cover it, and the covered content
cannot be read from the primary; pixelation defeats reading, not candidate-matching of short
known strings. The noise is seeded from a per-document salt stored in the master. The editor
shows the true result.

**The edit document** holds the cuts, an optional crop, the annotations (arrow, rectangle,
text, highlight, blur), all in original pixels, whether it has a border, plus the blur salt, so every edit stays
adjustable from the master.
Render order: blur (from original pixels) → crop → cuts and their labels → annotations, placed
through the coordinate map → border. The canvas caches the render up to the cuts and draws annotations
over it through the same Core code, so a drag repaints only annotations; a cut, crop or blur
change re-renders the cache. Undo is a stack of document values.

`⌘S` re-renders the primary, writes or updates the master, and closes the editor; Copy and For
Claude save the same way before they run, then close it. Closing with unsaved edits asks.

## Export

- **Copy** (`⌘C`) — the primary PNG, or in the editor the render of the edits it saves. **Drag** from the
  thumbnail or the editor's title bar.
- **For Claude** (`⌘⇧C`), shaped for Claude's ~1568px long-edge downscale:
  - tiles render at **1× (points)** — Retina doubles pixels without adding legible text;
  - a capture that fits is one image; taller ones split into ~1500px tiles overlapping ~100px,
    so every line appears whole in some tile;
  - `text.md` holds Vision OCR in reading order, panes on different backgrounds one after the
    other (`ReadingOrder.blocks`), each cut written in as `[⋯ 1,240 px hidden]`;
  - the clipboard receives `@<path>` references to every tile and `text.md`;
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
  split on height only, so a wide capture reaches Claude downscaled.

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
