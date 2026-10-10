# excerpt

![Platform](https://img.shields.io/badge/platform-macOS%2015%2B-000000?logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/swift-6-F05138?logo=swift&logoColor=white)
[![License](https://img.shields.io/github/license/lockyc/excerpt)](LICENSE)

A macOS screenshot tool that can **cut the middle out of a screenshot**. Keep a spreadsheet's
header rows and its totals, drop the thousand rows between, and the join is marked with a torn
seam that says how much was removed. It works across columns too, and on long scrolling
captures of web pages and forms.

Around that: area, window, fullscreen and scrolling capture, text capture (OCR), a floating
preview, an annotation editor, and an export that splits tall captures into tiles Claude can
read.

## Status

| | |
|---|---|
| Capture | Area (frozen screen), window, fullscreen, scrolling (auto-scroll or scroll it yourself, stitched with sticky bars kept once) → library + clipboard + thumbnail; hand checks pending |
| Editor | Arrow, rectangle, text, highlight, blur, crop and cut over the capture; ⌘S writes the primary and its master; hand checks pending |
| Core | Cuts render as torn seams; edits round-trip through the master PNG; frames stitch on row signatures |
| Next | Text capture and the For Claude export — see [docs/roadmap.md](docs/roadmap.md) |

macOS's own Screenshots shortcuts (⌘⇧3 / ⌘⇧4) must be turned off for Excerpt's defaults to fire.

## Build

```bash
just gate     # format check, build, tests
just run      # build the signed app and launch it
just deploy   # install to /Applications
```

Signing uses a `Developer ID Application` identity from your keychain; set
`EXCERPT_SIGN_IDENTITY` when more than one is present.

## License

MIT
