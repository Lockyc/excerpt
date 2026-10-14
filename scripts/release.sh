#!/usr/bin/env bash
# scripts/release.sh — notarize the signed app, and publish it as a GitHub release.
#   scripts/release.sh notarize          build/Excerpt.app, notarized and stapled, zipped to build/Excerpt.zip
#   scripts/release.sh publish NOTES.md  the above for VERSION, then tag v<VERSION>, fast-forward main, publish
# Needs APPLE_ID, APPLE_PASSWORD and APPLE_TEAM_ID in the env (the notary credentials).
#
# Every check is an explicit `if …; then fail; fi`: under `set -e` a bare `[ … ] || fail`
# or `! cmd || fail` is easy to misread, and a refusal must never fall through to the
# notarize, tag or gh steps.
set -euo pipefail

# A relative notes path is relative to the caller's directory, not the repo root.
notes_arg=${2:-}
case "$notes_arg" in
    "" | /*) ;;
    *) notes_arg=$PWD/$notes_arg ;;
esac

cd "$(dirname "$0")/.."

app=build/Excerpt.app
zip=build/Excerpt.zip
version=$(tr -d '[:space:]' < VERSION)

fail() {
    echo "release: $*" >&2
    exit 1
}

notarize() {
    local v
    for v in APPLE_ID APPLE_PASSWORD APPLE_TEAM_ID; do
        if [ -z "${!v:-}" ]; then
            fail "$v is not set; export the notary credentials first."
        fi
    done
    just bundle
    rm -f "$zip"
    ditto -c -k --keepParent "$app" "$zip"
    # A rejection may also exit non-zero; capture that so Apple's log still prints.
    local result=build/notary.json submitted=0
    xcrun notarytool submit "$zip" --apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" \
        --team-id "$APPLE_TEAM_ID" --wait --output-format json > "$result" || submitted=$?
    local status id
    status=$(plutil -extract status raw -o - "$result" 2> /dev/null || true)
    id=$(plutil -extract id raw -o - "$result" 2> /dev/null || true)
    if [ -z "$id" ]; then
        fail "notarytool submit failed (exit $submitted) before Apple accepted a submission."
    fi
    if [ "$submitted" -ne 0 ] || [ "$status" != Accepted ]; then
        xcrun notarytool log "$id" --apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" \
            --team-id "$APPLE_TEAM_ID" >&2 || true
        fail "notarization returned ${status:-no status} (notarytool exit $submitted)."
    fi
    xcrun stapler staple "$app"
    rm -f "$zip"
    ditto -c -k --keepParent "$app" "$zip"
    if ! spctl --assess --type execute "$app"; then
        fail "Gatekeeper refuses the stapled app."
    fi
    echo "✓ $zip — Excerpt $version, notarized"
}

# All refusals come before the first side effect (gate, notarize, tag, push, gh).
publish() {
    local notes=$1
    if [ ! -s "$notes" ]; then
        fail "name a notes file: just release NOTES.md"
    fi
    if [ "$(git rev-parse --abbrev-ref HEAD)" != dev ]; then
        fail "release from dev."
    fi
    if ! git diff --quiet || ! git diff --cached --quiet; then
        fail "the tree has uncommitted changes."
    fi
    git fetch --quiet --tags origin
    if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/dev)" ]; then
        fail "dev isn't pushed."
    fi
    if ! git merge-base --is-ancestor origin/main HEAD; then
        fail "main isn't an ancestor of dev."
    fi
    if git rev-parse --quiet --verify "refs/tags/v$version" > /dev/null; then
        fail "v$version is already tagged."
    fi
    just gate
    notarize
    git tag -a "v$version" -m "excerpt v$version"
    # From here a failure strands a local tag or a pushed main; the trap prints the way to finish.
    local release_cmd
    release_cmd="gh release create v$version $zip --verify-tag --title 'excerpt v$version' --notes-file '$notes'"
    trap 'echo "release: failed after tagging v'"$version"'; finish by hand: ${next:-}" >&2' EXIT
    next="git push origin HEAD:main && git push origin v$version && $release_cmd"
    git push origin HEAD:main
    next="git push origin v$version && $release_cmd"
    git push origin "v$version"
    next=$release_cmd
    gh release create "v$version" "$zip" --verify-tag --title "excerpt v$version" --notes-file "$notes"
    trap - EXIT
}

case "${1:-}" in
    notarize) notarize ;;
    publish) publish "$notes_arg" ;;
    *) fail "usage: scripts/release.sh notarize | publish NOTES.md" ;;
esac
