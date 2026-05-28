#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dist_dir="$root_dir/dist"
app_dir="$dist_dir/Caff.app"

"$root_dir/scripts/build_app.sh"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_dir/Contents/Info.plist")"
zip_path="$dist_dir/Caff-$version.zip"
checksum_path="$zip_path.sha256"

rm -f "$zip_path" "$checksum_path"
(
    cd "$dist_dir"
    ditto -c -k --sequesterRsrc --keepParent "Caff.app" "$(basename "$zip_path")"
)
shasum -a 256 "$zip_path" > "$checksum_path"

printf '%s\n' "$zip_path"
printf '%s\n' "$checksum_path"
