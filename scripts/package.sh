#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
swift build --disable-sandbox -c release
binary_dir="$(swift build --disable-sandbox -c release --show-bin-path)"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
app="dist/ApiDog.app"
iconset="$stage/ApiDog.iconset"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$iconset"
for size in 16 32 128 256 512; do
  double=$((size * 2))
  sips -z "$size" "$size" assets/ApiDog.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
  sips -z "$double" "$double" assets/ApiDog.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/ApiDog.icns"
install -m 755 "$binary_dir/ApiDog" "$app/Contents/MacOS/ApiDog"
cp scripts/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"

mkdir "$stage/volume"
ditto "$app" "$stage/volume/ApiDog.app"
ln -s /Applications "$stage/volume/Applications"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' scripts/Info.plist)"
image="dist/ApiDog-${version}-$(uname -m).dmg"
hdiutil create -ov -volname ApiDog -fs HFS+ -srcfolder "$stage/volume" -format UDZO "$image"
