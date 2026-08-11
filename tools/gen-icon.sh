#!/bin/bash
# Regenerate the app icon: render icon_1024.png, build the .iconset, make AppIcon.icns.
set -e
cd "$(dirname "$0")/.."
mkdir -p icons build
swiftc -O tools/make-icon.swift -framework AppKit -o build/make-icon
build/make-icon icons/icon_1024.png

ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
# name:pixel-size pairs for each iconset slot (Apple's required set).
for pair in \
  16x16:16 16x16@2x:32 32x32:32 32x32@2x:64 \
  128x128:128 128x128@2x:256 256x256:256 256x256@2x:512 \
  512x512:512 512x512@2x:1024; do
  name="${pair%%:*}"; px="${pair##*:}"
  sips -z "$px" "$px" icons/icon_1024.png --out "$ICONSET/icon_${name}.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o icons/AppIcon.icns
echo "built icons/AppIcon.icns"
