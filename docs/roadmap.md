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
| 0 | **Core** — capture document, renderer, cut geometry + torn seam, coordinate map, gap detection, edits in `iTXt` | Golden-image tests for cuts and annotations; edits round-trip through a PNG | Not started |
| 1 | **Capture shell** — menu bar, hotkeys, area (frozen) / window / fullscreen, library save, clipboard, thumbnail; signed `.app` via `just app` | A capture lands in the library with the dated name and on the clipboard | Not started |
| 2 | **Editor** — canvas over Core's renderer, the eight tools, undo, save to primary + master | Cut a spreadsheet capture, reopen it from the library, adjust the cut | Not started |
| 3 | **Scrolling capture** — auto-scroll, stitcher, sticky regions, manual fallback, uncertain-stop | Stitcher fixtures (sticky header, long form, animated element) pass; a real long page captures cleanly | Not started |
| 4 | **Text + Claude** — capture text (⌘⇧5), all-in-one selector (⌘⇧6), For Claude export | A 10,000px capture pastes into Claude Code as legible tiles + `text.md` with cut markers | Not started |
| 5 | **v1 release** — notarized build, `install.sh` + `/excerpt:install`, README curation | Fresh-machine install from the curl one-liner | Not started |

## After v1

| Item | What | Next action |
|---|---|---|
| Smart redaction | On-device OCR finds emails, tokens, IPs, names; one-click destructive redaction, toggleable per region before save | Design the detector set and the review UI |
| Live-text editing | Click text in a capture and retype it, matching font and background | Spike Vision text bounds + font matching on a UI screenshot |
| Horizontal scrolling capture | The stitcher along the x axis, for wide sheets | Generalise the stitcher's axis once vertical is proven |

## Sequencing

<!-- Priority order across the After-v1 items: set by the owner. -->
