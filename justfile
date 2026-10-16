# `default` pipes `just --list` through a small stock-perl filter that clips long recipe
# docs to your terminal width (…) instead of wrapping. Self-contained — no external files;
# falls back to plain `just --list` where perl is absent. Edit the recipes below, not this.
# List available recipes
default:
    @if command -v perl >/dev/null 2>&1; then just --color always --list | perl -CS -Mutf8 -lpe 'BEGIN{($w)=`stty size 2>/dev/null </dev/tty`=~/ (\d+)/; $w||=100; $col=(-t STDOUT && !exists $ENV{NO_COLOR})} s/\e\[[0-9;]*m//g unless $col; (my $v=$_)=~s/\e\[[0-9;]*m//g; if(length($v)>$w){my($o,$n)=("",0); while(length && $n<$w-1){ if($col && s/^(\e\[[0-9;]*m)//){$o.=$1}else{s/^(.)//;$o.=$1;$n++} } $_=$o."…".($col?"\e[0m":"")}'; else just --list; fi

sign_identity := env("EXCERPT_SIGN_IDENTITY", "Developer ID Application")
app_dir := "build/Excerpt.app"

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
    shellcheck install.sh scripts/*.sh
    swift format lint --strict --recursive Package.swift Sources Tests
    swift build
    swift test

[group("app")]
[doc("Build the signed Excerpt.app into build/")]
bundle:
    swift build -c release --product Excerpt
    rm -rf {{app_dir}}
    mkdir -p {{app_dir}}/Contents/MacOS
    cp "$(swift build -c release --show-bin-path)/Excerpt" {{app_dir}}/Contents/MacOS/Excerpt
    sed "s/__VERSION__/$(tr -d '[:space:]' < VERSION)/g" Support/Info.plist > {{app_dir}}/Contents/Info.plist
    codesign --force --options runtime --timestamp --sign "{{sign_identity}}" {{app_dir}}

[group("app")]
[doc("Build and launch the app from build/")]
run: bundle quit
    @just launch {{app_dir}}

[group("app")]
[doc("Build, install to /Applications, launch")]
install: bundle quit
    rm -rf /Applications/Excerpt.app
    ditto {{app_dir}} /Applications/Excerpt.app
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

[group("release")]
[doc("Build, notarize and staple the app; zip it to build/Excerpt.zip")]
notarize:
    scripts/release.sh notarize

[group("release")]
[doc("Release VERSION: notarize, tag, fast-forward main, publish with NOTES")]
[no-cd]
release notes:
    "{{justfile_directory()}}/scripts/release.sh" publish "{{notes}}"
