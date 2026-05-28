#!/usr/bin/env bash
set -euo pipefail

app_name="Caff"
repo_url="${CAFF_REPO_URL:-https://github.com/majiayu000/caff.git}"
repo_ref="${CAFF_REF:-main}"
install_dir="${CAFF_INSTALL_DIR:-/Applications}"
open_after_install="${CAFF_OPEN:-1}"
source_dir="${CAFF_SOURCE_DIR:-}"
tmp_dir=""

die() {
    printf 'caff install: %s\n' "$1" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

cleanup() {
    if [[ -n "$tmp_dir" ]]; then
        rm -rf "$tmp_dir"
    fi
}
trap cleanup EXIT

[[ "$(uname -s)" == "Darwin" ]] || die "Caff only supports macOS"

for command_name in git swift iconutil plutil codesign ditto; do
    require_command "$command_name"
done

if pgrep -x "$app_name" >/dev/null 2>&1; then
    die "quit Caff before installing"
fi

if [[ -n "$source_dir" ]]; then
    root_dir="$(cd "$source_dir" && pwd)"
else
    tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/caff-install.XXXXXX")"
    git clone --depth 1 --branch "$repo_ref" "$repo_url" "$tmp_dir/caff"
    root_dir="$tmp_dir/caff"
fi

[[ -x "$root_dir/scripts/build_app.sh" ]] || die "build script not found at $root_dir/scripts/build_app.sh"

"$root_dir/scripts/build_app.sh"

source_app="$root_dir/dist/$app_name.app"
target_app="$install_dir/$app_name.app"

[[ -d "$source_app" ]] || die "expected app bundle not found: $source_app"
mkdir -p "$install_dir"

if [[ ! -w "$install_dir" ]]; then
    die "cannot write to $install_dir; set CAFF_INSTALL_DIR=\"$HOME/Applications\" or rerun with suitable permissions"
fi

rm -rf "$target_app"
ditto "$source_app" "$target_app"
codesign --verify --deep --strict "$target_app"

printf 'Installed %s\n' "$target_app"

if [[ "$open_after_install" != "0" ]]; then
    open "$target_app"
fi
