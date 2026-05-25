#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_name="Caff"
bundle_id="local.caff"
build_dir="$root_dir/.build/release"
dist_dir="$root_dir/dist"
app_dir="$dist_dir/$app_name.app"
resources_dir="$root_dir/Resources"
iconset_dir="$resources_dir/AppIcon.iconset"
icns_path="$resources_dir/Caff.icns"

swift build -c release --package-path "$root_dir"
swift "$root_dir/scripts/render_app_icon.swift" "$resources_dir" >/dev/null
iconutil -c icns "$iconset_dir" -o "$icns_path"

rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$build_dir/caff" "$app_dir/Contents/MacOS/$app_name"
cp "$icns_path" "$app_dir/Contents/Resources/Caff.icns"

cat > "$app_dir/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$app_name</string>
    <key>CFBundleIdentifier</key>
    <string>$bundle_id</string>
    <key>CFBundleIconFile</key>
    <string>Caff</string>
    <key>CFBundleName</key>
    <string>$app_name</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>$bundle_id</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>caff</string>
            </array>
        </dict>
    </array>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

plutil -lint "$app_dir/Contents/Info.plist"
codesign --force --deep --sign - "$app_dir"
codesign --verify --deep --strict "$app_dir"
echo "$app_dir"
