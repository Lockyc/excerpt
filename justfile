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
[doc("Pre-merge gate: format check, build, tests")]
gate:
    swift format lint --strict --recursive Package.swift Sources Tests
    swift build
    swift test

[group("app")]
[doc("Build the signed Excerpt.app into build/")]
app:
    swift build -c release --product Excerpt
    rm -rf {{app_dir}}
    mkdir -p {{app_dir}}/Contents/MacOS
    cp "$(swift build -c release --show-bin-path)/Excerpt" {{app_dir}}/Contents/MacOS/Excerpt
    sed "s/__VERSION__/$(cat VERSION)/g" Support/Info.plist > {{app_dir}}/Contents/Info.plist
    codesign --force --options runtime --sign "{{sign_identity}}" {{app_dir}}

[group("app")]
[doc("Build and launch the app from build/")]
run: app
    -killall Excerpt 2>/dev/null
    open {{app_dir}}

[group("app")]
[doc("Build, install to /Applications, launch")]
deploy: app
    -killall Excerpt 2>/dev/null
    rm -rf /Applications/Excerpt.app
    ditto {{app_dir}} /Applications/Excerpt.app
    open /Applications/Excerpt.app
