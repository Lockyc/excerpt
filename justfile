# `default` pipes `just --list` through a small stock-perl filter that clips long recipe
# docs to your terminal width (…) instead of wrapping. Self-contained — no external files;
# falls back to plain `just --list` where perl is absent. Edit the recipes below, not this.
# List available recipes
default:
    @if command -v perl >/dev/null 2>&1; then just --color always --list | perl -CS -Mutf8 -lpe 'BEGIN{($w)=`stty size 2>/dev/null </dev/tty`=~/ (\d+)/; $w||=100; $col=(-t STDOUT && !exists $ENV{NO_COLOR})} s/\e\[[0-9;]*m//g unless $col; (my $v=$_)=~s/\e\[[0-9;]*m//g; if(length($v)>$w){my($o,$n)=("",0); while(length && $n<$w-1){ if($col && s/^(\e\[[0-9;]*m)//){$o.=$1}else{s/^(.)//;$o.=$1;$n++} } $_=$o."…".($col?"\e[0m":"")}'; else just --list; fi

sign_identity := env("APPLE_SIGNING_IDENTITY", "Developer ID Application")
app := "build/Excerpt.app"
info_plist := "Support/Info.plist"

[group("dev")]
[doc("Compile all targets (debug)")]
build:
    swift build

[group("dev")]
[doc("Run the unit tests")]
test:
    swift test

[group("dev")]
[doc("Format sources in place")]
fmt:
    swift format --in-place --recursive Package.swift Sources Tests

[group("dev")]
[doc("Pre-merge gate: shellcheck, format check, build, tests")]
gate:
    shellcheck install.sh
    swift format lint --strict --recursive Package.swift Sources Tests
    swift build
    swift test

[group("app")]
[doc("Render Support/AppIcon.icns and the README's icon.png from the Support/icon.svg master")]
icons:
    plate icon --icns Support/AppIcon.icns --png 256:Support/icon.png Support/icon.svg

[group("app")]
[doc("Build the signed Excerpt.app, Sparkle embedded, into build/")]
bundle:
    #!/usr/bin/env bash
    set -euo pipefail
    swift build -c release --product Excerpt
    bin=$(swift build -c release --show-bin-path)
    rm -rf {{app}}
    mkdir -p {{app}}/Contents/MacOS {{app}}/Contents/Resources {{app}}/Contents/Frameworks
    cp "$bin/Excerpt" {{app}}/Contents/MacOS/Excerpt
    cp Support/AppIcon.icns {{app}}/Contents/Resources/AppIcon.icns
    install_name_tool -add_rpath @executable_path/../Frameworks {{app}}/Contents/MacOS/Excerpt
    ditto "$bin/Sparkle.framework" {{app}}/Contents/Frameworks/Sparkle.framework
    sed "s/__VERSION__/$(tr -d '[:space:]' < VERSION)/g" {{info_plist}} > {{app}}/Contents/Info.plist
    # Inside-out: each nested Sparkle helper before the framework, the framework before the app.
    sign=(codesign --force --options runtime --timestamp --sign "{{sign_identity}}")
    sparkle={{app}}/Contents/Frameworks/Sparkle.framework
    "${sign[@]}" "$sparkle/Versions/B/XPCServices/Installer.xpc"
    "${sign[@]}" --preserve-metadata=entitlements "$sparkle/Versions/B/XPCServices/Downloader.xpc"
    "${sign[@]}" "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app" "$sparkle"
    "${sign[@]}" {{app}}

[group("app")]
[doc("Print the directory holding Sparkle's sign_update and generate_keys")]
sparkle-bin:
    @swift package resolve >/dev/null
    @echo "{{justfile_directory()}}/.build/artifacts/sparkle/Sparkle/bin"

[group("app")]
[doc("Build and launch the app from build/")]
run: bundle quit
    @just launch {{app}}

[group("app")]
[doc("Build, install to /Applications, launch")]
install: bundle quit
    rm -rf /Applications/Excerpt.app
    ditto {{app}} /Applications/Excerpt.app
    @just launch /Applications/Excerpt.app

# Quits any running Excerpt, force-killing one still alive after 3s.
[private]
quit:
    #!/usr/bin/env bash
    killall Excerpt 2>/dev/null || exit 0
    for _ in {1..30}; do pgrep -x Excerpt >/dev/null || exit 0; sleep 0.1; done
    killall -9 Excerpt 2>/dev/null
    while pgrep -x Excerpt >/dev/null; do sleep 0.1; done

# Opens the app at `path`, retrying for up to 5s: LaunchServices keeps a quit Excerpt on its
# books briefly after the process is gone, and `open` fails with error -600 until it lets go.
[private]
launch path:
    #!/usr/bin/env bash
    for _ in {1..20}; do open "{{path}}" 2>/dev/null && exit 0; sleep 0.25; done
    open "{{path}}"
