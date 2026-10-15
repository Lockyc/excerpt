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

## Install

Needs macOS 15 or later.

```bash
curl -fsSL https://raw.githubusercontent.com/lockyc/excerpt/main/install.sh | bash
```

The installer downloads the latest release, checks that it is signed by Excerpt's developer and
notarized by Apple, then installs `/Applications/Excerpt.app`, links the `excerpt` command into
`/usr/local/bin` and starts the app in the menu bar. It asks for your password only when one of
those folders isn't writable. From a clone of this repo, Claude Code's `/excerpt:install` runs
the same install and checks the command works from a new shell.

**Update** by running the installer again; it quits a running Excerpt, replaces it and starts
the new one.

**Uninstall** by quitting Excerpt, deleting `/Applications/Excerpt.app`,
`/usr/local/bin/excerpt` and the cache `~/Library/Caches/excerpt`, running
`defaults delete com.lockyc.excerpt`, and removing Excerpt from Screen Recording and
Accessibility in System Settings → Privacy & Security. Your captures stay where they were saved.

## Use

| Default hotkey | Capture |
|---|---|
| ⌘⇧3 | Window |
| ⌘⇧4 | Area (the screen freezes while you select) |
| ⌘⇧5 | Text — OCR straight to the clipboard, no file |
| ⌘⇧6 | All-in-one selector: area, window, fullscreen, scrolling or text |

macOS's own screenshot shortcuts hold ⌘⇧3 to ⌘⇧5 until they are turned off in System Settings →
Keyboard → Keyboard Shortcuts → Screenshots, or Excerpt's are rebound in its Settings. Excerpt's
menu flags any shortcut macOS still holds.

The first capture asks for **Screen Recording** (System Settings → Privacy & Security → Screen &
System Audio Recording); reopen Excerpt after granting it. Scrolling capture's auto-scroll also
asks for **Accessibility**; scrolling the selected region yourself doesn't need it. Excerpt
stitches as you go, and your own scrolling takes over from auto-scroll at any point.

Each capture is saved to `~/Documents/Screenshots/` (a setting), copied to the clipboard and
shown as a thumbnail with **Edit**, **For Claude** and **Close**. Files in that folder older
than 30 days move into `YYYY/MM-Month/` folders, names unchanged (also a setting). The editor has
arrow, rectangle, text (plain or on a background of its colour), numbered steps, highlight, blur,
crop and **cut** (`C`); a selected item's colour, size and options float beside it. Cut: drag across the rows or columns
to remove, and the join becomes a torn seam. Cut and blurred content never reaches the saved
file; the original and your edits stay in a separate `… original.png`, so reopening a capture
lets you adjust them; the menu bar's **Recent Captures** reopens one. **Border** frames the image in a solid line of your colour and width, so a screenshot pasted
into an email stands apart from it. **Save** (⌘S) saves, copies the image and closes the editor.

**For Claude** (⇧⌘C in the editor) writes the capture as tiles sized for Claude to read plus a
`text.md` of its text with each cut marked, and copies `@` references to paste into Claude
Code. The same works for any image file from the command line:

```bash
excerpt read shot.png   # text on stdout, tile paths on stderr
```

Known limits: tiles split on height only, so a capture over 2000pt wide reaches Claude downscaled;
`text.md` reads columns that share a background row by row; scrolling capture stops rather than
guess on pages with large animations or video.

## Build from source

Needs Xcode or the Command Line Tools with Swift 6, [`just`](https://github.com/casey/just),
and `shellcheck` for the gate.

```bash
just gate     # shellcheck, format check, build, tests
just run      # build the signed app and launch it
just install  # build, install to /Applications and launch

swift run Excerpt read shot.png   # the excerpt command, without building the app
```

Signing uses a `Developer ID Application` identity from your keychain; set
`EXCERPT_SIGN_IDENTITY` when more than one is present. Without one,
`EXCERPT_SIGN_IDENTITY=- just run` signs ad hoc, and macOS then asks for Screen Recording again
after each rebuild. `just install` doesn't link the `excerpt` command; link
`/Applications/Excerpt.app/Contents/MacOS/Excerpt` as `excerpt` on your `PATH` to get it.

What's planned is in [docs/roadmap.md](docs/roadmap.md).

## License

MIT
