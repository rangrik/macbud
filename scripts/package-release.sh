#!/bin/bash
set -euo pipefail

app="${1:?Usage: package-release.sh /path/to/MacBud.app}"
codesign --verify --deep --strict "$app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
mkdir -p dist
archive="MacBud-${version}-macOS.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "dist/$archive"
(cd dist && shasum -a 256 "$archive" > "$archive.sha256")
printf 'Packaged dist/%s\n' "$archive"
