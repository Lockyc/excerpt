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
| Capture | Area (frozen screen), window, fullscreen → library + clipboard + thumbnail |
| Core | Cuts render as torn seams; edits round-trip through the master PNG |
| Next | The editor and cut tool — see [docs/roadmap.md](docs/roadmap.md) |

macOS's own Screenshots shortcuts (⌘⇧3 / ⌘⇧4) must be turned off for Excerpt's defaults to fire;
Excerpt flags it in the menu and Settings.

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
