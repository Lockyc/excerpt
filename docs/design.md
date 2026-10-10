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
| `ExcerptCapture` | ScreenCaptureKit capture, the multi-display selection overlay, the auto-scroll driver that feeds frames to Core's stitcher | Core |
| `ExcerptEditor` | Canvas, tools, undo; edits Core's document | Core |
| `ExcerptExport` | Vision OCR and the For Claude bundle (tiles + `text.md`), with no UI | Core, Vision |
| `Excerpt` (app) | Menu bar, global hotkeys, preview thumbnail, settings, export UI, file I/O; the `excerpt read` subcommand | all |

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
  pixels are the untouched capture and never change; the edit document (`excerpt.edits`, JSON)
  lives in a PNG `iTXt` chunk, the only part a re-save rewrites. An unedited capture is one file.
- **Re-editing** either file loads the original plus its edits; saving re-renders the primary.
  A primary whose original is gone opens as a flat image.
- Sidecar files and a separate edits database are both wrong here: library files get moved and
  sorted by other tools, which would orphan either one. The edits travel inside the master.
- "For Claude" output is scratch, not library content: `~/Library/Caches/excerpt/claude/<capture
  name>/`, pruned after 7 days.

## The cut tool

**Model.** A cut is an axis plus a half-open range in original pixels. A *horizontal* cut
removes rows (the image gets shorter); a *vertical* cut removes columns (narrower). Any number
of each; overlapping or touching same-axis cuts merge. Rows are removed before columns, so every
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

Hotkeys use Carbon `RegisterEventHotKey` (no permission, no dependency) and are all rebindable.
A binding Carbon reports as taken, or that an enabled macOS shortcut holds, is flagged in the
menu and Settings, never failed silently.

- **Area:** the screen freezes when selection starts (a still of every display is taken first,
  and the selection is cut from it), so hover states and open menus survive. Crosshair, loupe,
  W×H readout; `Space` moves the selection, `Esc` cancels.
- **Window:** hover-highlight, click; placed on a plain backdrop with padding (both settings).
- **Fullscreen:** the display under the cursor.
- Desktop icons and excerpt's own windows are excluded through the `SCContentFilter`.
- **After every capture** the file is saved, copied to the clipboard, and shown as a large
  thumbnail (Copy · Edit · For Claude · Close, draggable) that closes after 15s (paused while
  the pointer is over it), or on drag-out. Shutter sound on.

### Scrolling capture (vertical)

1. Select the scrolling region, press `Return`.
2. **Auto-scroll** posts scroll-wheel events at the region's centre, ~60% of its height per
   step, then waits for the frame to settle (two identical `SCStream` frames, or ~300ms).
3. **Stitching** (Core): frames reduce to row signatures; the offset from the previous frame is
   the one maximising matching rows in the overlap. **Sticky regions** — top/bottom rows
   unchanged while the rows between them move — are kept once: the header from the first frame,
   the footer from the last.
4. Stops on two consecutive no-movement steps, on `Return`, or at a maximum height (default
   30,000px).
5. **Manual fallback** when a step produces no movement before the end, or Accessibility is not
   granted: the HUD reads "Scroll the page yourself · Return when done" and frames are sampled
   and stitched as the user scrolls.
6. A live preview of the stitch sits beside the region.
7. An **uncertain stitch** (no offset clears the confidence threshold — video, animation) stops
   and keeps what is stitched; it never fabricates a seam. The HUD says where it stopped.

Permissions are requested on first use, per feature: Screen Recording for any capture,
Accessibility for auto-scroll only.

## Editor

Opens from the thumbnail's Edit, or by opening a capture (registered as an Open With handler
for PNG, not the default). Fits to width; tall captures scroll. Floats above other windows; no
Dock icon.

Tools: `V` select · `A` arrow · `R` rectangle · `T` text · `H` highlight · `B` blur · `K` crop ·
`C` cut. Six colours, three sizes (one control sets stroke and text). The arrow drag
**starts at the head**. Crop snaps using the same gap detection as cuts.

**Blur is destructive**: pixelation in ≥12pt blocks over noise, so the covered content cannot be
read from the primary; pixelation defeats reading, not candidate-matching of short known
strings. The noise is seeded from a per-document salt stored in the master. The editor shows the
true result.

**The edit document** holds the cuts, an optional crop, the annotations (arrow, rectangle,
text, highlight, blur), all in original pixels, plus the blur salt, so every edit stays
adjustable from the master.
Render order: blur (from original pixels) → crop → cuts and their labels → annotations, placed
through the coordinate map. The canvas caches the render up to the cuts and draws annotations
over it through the same Core code, so a drag repaints only annotations; a cut, crop or blur
change re-renders the cache. Undo is a stack of document values.

`⌘S` re-renders the primary and writes or updates the master. Closing with unsaved edits asks.

## Export

- **Copy** (`⌘C`) — the primary PNG, or in the editor the current render. **Drag** from the
  thumbnail or the editor's title bar.
- **For Claude** (`⌘⇧C`), shaped for Claude's ~1568px long-edge downscale:
  - tiles render at **1× (points)** — Retina doubles pixels without adding legible text;
  - a capture that fits is one image; taller ones split into ~1500px tiles overlapping ~100px,
    so every line appears whole in some tile;
  - `text.md` holds Vision OCR in reading order, each cut written in as `[⋯ 1,240 px hidden]`;
  - the clipboard receives `@<path>` references to every tile and `text.md`.
- **`excerpt read <image>`** — the same bundle for any image file, not only a capture, so a
  Claude session handed a large screenshot can read it. The app binary runs it headless when
  given arguments, before any `NSApplication` starts. It prints `text.md` to stdout and the tile
  paths to stderr, and needs no Screen Recording permission. A file with an excerpt edit
  document gets its cut markers. Any other file is treated as uncut, with Retina scale read
  from its DPI metadata.
