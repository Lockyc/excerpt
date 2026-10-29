You are installing or updating **Excerpt** — a macOS menu-bar screenshot tool that cuts the middle out of screenshots.

## 1. Check the Mac

```bash
sw_vers -productVersion
```

Excerpt needs macOS 15 or later. On an older Mac, say so and stop.

## 2. Install

From an excerpt checkout (`[ -f install.sh ] && [ -f Package.swift ]`), ask with AskUserQuestion:
- **Latest release** (recommended): `bash install.sh`
- **This checkout's code**: `just install`.

Outside a checkout, run `curl -fsSL https://raw.githubusercontent.com/lockyc/excerpt/main/install.sh | bash`.

If the installer needs `sudo`, the user types their password in this session: suggest `! <the command>`.

## 3. Permissions and shortcuts

Tell the user, as a short list:
- The first capture asks for **Screen Recording**: System Settings → Privacy & Security → Screen & System Audio Recording → Excerpt on, then reopen Excerpt.
- **Scrolling capture** also asks for Accessibility (Privacy & Security → Accessibility).
- macOS's own screenshot shortcuts hold ⌘⇧3–⌘⇧5 until turned off in System Settings → Keyboard → Keyboard Shortcuts → Screenshots, or Excerpt's are rebound in its Settings. Excerpt's menu flags any shortcut macOS still holds.

## 4. Done

Report the installed version (`/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' /Applications/Excerpt.app/Contents/Info.plist`).
