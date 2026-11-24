#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
swift build --disable-sandbox -c release
binary_dir="$(swift build --disable-sandbox -c release --show-bin-path)"
app="dist/ApiDog.app"
mkdir -p "$app/Contents/MacOS"
install -m 755 "$binary_dir/ApiDog" "$app/Contents/MacOS/ApiDog"
cp scripts/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/volume"
ditto "$app" "$stage/volume/ApiDog.app"
ln -s /Applications "$stage/volume/Applications"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' scripts/Info.plist)"
image="dist/ApiDog-${version}-$(uname -m).dmg"
hdiutil create -ov -volname ApiDog -fs HFS+ -srcfolder "$stage/volume" -format UDZO "$image"
