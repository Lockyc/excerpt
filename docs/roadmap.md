---
type: reference
description: excerpt's phased roadmap — the shippable slices to v1, then the post-v1 features.
links:
  - rel: part-of
    to: CLAUDE.md
---

# Roadmap

Each phase is a shippable slice with an acceptance gate. The design behind every item is
[design.md](design.md).

## To v1

| Phase | Slice | Gate | Lane |
|---|---|---|---|
| 0 | **Core** — capture document, renderer, cut geometry + torn seam, coordinate map, gap detection, edits in `iTXt`, library naming and store | Golden-image tests for cuts; edits round-trip through the master PNG | Shipped |
| 1 | **Capture shell** — menu bar, default hotkeys, area (frozen) / window / fullscreen, library save, clipboard, thumbnail, settings; signed `.app` via `just bundle` | A capture lands in the library with the dated name and on the clipboard | Built — hand checks pending |
| 2 | **Editor** — annotation model + rendering in Core, canvas over Core's renderer, the eight tools, undo, save to primary + master | Cut a spreadsheet capture, reopen it from the library, adjust the cut | Built — hand checks pending |
| 3 | **Scrolling capture** — auto-scroll, stitcher, sticky regions, manual fallback, uncertain-stop | Stitcher fixtures (sticky header, long form, animated element) pass; a real long page captures cleanly | Built — hand checks pending |
| 4 | **Text + Claude** — capture text (⌘⇧5), all-in-one selector (⌘⇧6), hotkey rebinding, For Claude export, `excerpt read <image>` over the same bundle builder | A 10,000px capture pastes into Claude Code as legible tiles + `text.md` with cut markers; `excerpt read` on a foreign 2× screenshot prints its text and legible tiles | Built — hand checks pending |
| 5 | **v1 release** — notarized build, `install.sh` + `/excerpt:install` (links `excerpt` onto `PATH`), README curation | Fresh-machine install from the curl one-liner; `excerpt read` runs from a new shell | Built — v1.0.0 held until the Phase 1–4 hand checks pass |

## After v1

| Item | What | Next action |
|---|---|---|
| Item bar, steps, text background | The selection's options float beside it; numbered step markers; text on a contrasting pill, previewed through the renderer while typed | Built — hand checks pending |
| Library filing | Files older than 30 days move from the library's top level into `YYYY/MM-Month/` folders, names unchanged, masters with their primaries; a setting, on by default | Built — hand checks pending |
| Path tool | `P` draws polylines and polygons by click or freehand, closed paths optionally filled, vertices editable; edit document version 5 | Built — hand checks pending |
| Smart redaction | On-device OCR finds emails, tokens, IPs, names; one-click destructive redaction, toggleable per region before save | Design the detector set and the review UI |
| Live-text editing | Click text in a capture and retype it, matching font and background | Spike Vision text bounds + font matching on a UI screenshot |
| Horizontal scrolling capture | The stitcher along the x axis, for wide sheets | Generalise the stitcher's axis once vertical is proven |
| Tiling wide captures | Tiles split on height only, so a capture over 2000pt wide arrives downscaled and its text shrinks | Split tiles on width too and teach `text.md` the tile grid |
| In-app updates | Re-running the installer is the update path | Decide between Sparkle and a release check |
| Multi-core PNG encoding | ImageIO encodes a PNG on one core: about 2s for a stitch at `Stitcher.defaultMaximumHeight` (3000 px wide) before its thumbnail shows, and a quarter of a second for a full Retina screen | Spike row-band deflate across cores (zlib's sync flush lets the bands join into one IDAT stream) against `PNGCodec.encode` |

## Sequencing

<!-- Priority order across the After-v1 items: set by the owner. -->
