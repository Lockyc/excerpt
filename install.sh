#!/usr/bin/env bash
# install.sh — install or update Excerpt from its latest GitHub release.
#   curl -fsSL https://raw.githubusercontent.com/lockyc/excerpt/main/install.sh | bash
# Installs /Applications/Excerpt.app and links `excerpt` into /usr/local/bin. Re-run to update.
# EXCERPT_ZIP_URL, EXCERPT_APP_DIR and EXCERPT_BIN_DIR override the download and the two places.
set -euo pipefail

main() {
    zip_url=${EXCERPT_ZIP_URL:-https://github.com/lockyc/excerpt/releases/latest/download/Excerpt.zip}
    app_dir=${EXCERPT_APP_DIR:-/Applications}
    bin_dir=${EXCERPT_BIN_DIR:-/usr/local/bin}
    team=G9V8U6ZU5E

    fail() { echo "excerpt: $*" >&2; exit 1; }

    [ "$(uname)" = Darwin ] || fail "Excerpt runs on macOS only."
    major=$(sw_vers -productVersion | cut -d. -f1)
    [ "$major" -ge 15 ] || fail "Excerpt needs macOS 15 or later; this Mac runs $(sw_vers -productVersion)."

    # Runs a command as the user, or with sudo when $1 (a directory) isn't writable.
    in_dir() {
        local dir=$1
        shift
        if [ -w "$dir" ]; then "$@"; else sudo "$@"; fi
    }

    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT

    echo "→ downloading Excerpt"
    curl -fsSL "$zip_url" -o "$work/Excerpt.zip" || fail "couldn't download $zip_url"
    ditto -x -k "$work/Excerpt.zip" "$work/unzipped" || fail "the download isn't a zip."
    new="$work/unzipped/Excerpt.app"
    [ -d "$new" ] || fail "the download holds no Excerpt.app."
    [ -z "$(find "$work/unzipped" -maxdepth 1 -type l)" ] && [ ! -L "$new" ] \
        || fail "the download's Excerpt.app is a link."
    codesign --verify --strict --deep "$new" 2>/dev/null || fail "the download's signature doesn't verify."
    info=$(codesign -dv "$new" 2>&1) || fail "the download's signature can't be read."
    printf '%s\n' "$info" | grep -qx "TeamIdentifier=$team" \
        || fail "the download isn't signed by Excerpt's developer."
    spctl --assess --type execute "$new" 2>/dev/null || fail "macOS won't open the download: it isn't notarized."
    version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$new/Contents/Info.plist")

    if pgrep -U "$(id -u)" -x Excerpt >/dev/null; then
        echo "→ quitting the running Excerpt"
        pkill -U "$(id -u)" -x Excerpt || true
        for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -U "$(id -u)" -x Excerpt >/dev/null || break; sleep 0.5; done
        ! pgrep -U "$(id -u)" -x Excerpt >/dev/null || fail "Excerpt didn't quit; quit it from its menu and re-run."
    fi

    target="$app_dir/Excerpt.app"
    echo "→ installing Excerpt $version to $target"
    [ -d "$app_dir" ] || in_dir "$(dirname "$app_dir")" mkdir -p "$app_dir"
    staged="$app_dir/.Excerpt.app.new"
    in_dir "$app_dir" rm -rf "$staged"
    in_dir "$app_dir" ditto "$new" "$staged" || fail "couldn't copy Excerpt into $app_dir."
    in_dir "$app_dir" rm -rf "$target" \
        || fail "couldn't remove the old $target. Allow your terminal in System Settings > Privacy & Security > App Management, or drag the old app to the Trash, then re-run."
    in_dir "$app_dir" mv "$staged" "$target" || fail "couldn't move Excerpt into place at $target."

    echo "→ linking $bin_dir/excerpt"
    [ -d "$bin_dir" ] || in_dir "$(dirname "$bin_dir")" mkdir -p "$bin_dir"
    in_dir "$bin_dir" ln -sfn "$target/Contents/MacOS/Excerpt" "$bin_dir/excerpt"
    "$bin_dir/excerpt" help >/dev/null || fail "$bin_dir/excerpt doesn't run."

    open "$target"
    echo "✓ Excerpt $version is in $target and running in the menu bar."
    echo "  \`excerpt read <image>\` reads any image for Claude."
    case ":$PATH:" in
        *":$bin_dir:"*) ;;
        *) echo "  $bin_dir isn't on your PATH; add it to run \`excerpt\` by name." ;;
    esac
}

main "$@"
