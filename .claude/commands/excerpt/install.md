You are installing or updating **Excerpt** — a macOS menu-bar screenshot tool that cuts the middle out of screenshots, with `excerpt read <image>` for Claude.

## 1. Check the Mac

```bash
sw_vers -productVersion
```

Excerpt needs macOS 15 or later. On an older Mac, say so and stop.

## 2. Install

From an excerpt checkout (`[ -f install.sh ] && [ -f Package.swift ]`), ask with AskUserQuestion:
- **Latest release** (recommended): `bash install.sh`
- **This checkout's code**: `just deploy`, then `ln -sfn /Applications/Excerpt.app/Contents/MacOS/Excerpt /usr/local/bin/excerpt` (with `sudo` if `/usr/local/bin` isn't writable).

Outside a checkout, run `curl -fsSL https://raw.githubusercontent.com/lockyc/excerpt/main/install.sh | bash`.

If the installer needs `sudo`, the user types their password in this session: suggest `! <the command>`.

## 3. Check it from a new shell

```bash
"$SHELL" -lc 'command -v excerpt && excerpt help'
```

Expect the link's path and the usage text. If `excerpt` isn't found, `/usr/local/bin` is missing from `PATH`: show the line for the user's shell (fish: `fish_add_path /usr/local/bin`; zsh/bash: `export PATH="/usr/local/bin:$PATH"` in `~/.zprofile` / `~/.bash_profile`) and offer to add it.

## 4. Permissions and shortcuts

Tell the user, as a short list:
- The first capture asks for **Screen Recording**: System Settings → Privacy & Security → Screen & System Audio Recording → Excerpt on, then reopen Excerpt.
- **Scrolling capture** also asks for Accessibility (Privacy & Security → Accessibility).
- macOS's own screenshot shortcuts hold ⌘⇧3–⌘⇧5 until turned off in System Settings → Keyboard → Keyboard Shortcuts → Screenshots, or Excerpt's are rebound in its Settings. Excerpt's menu flags any shortcut macOS still holds.

## 5. Done

Report the installed version (`/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' /Applications/Excerpt.app/Contents/Info.plist`) and that `excerpt read <image>` is ready.
