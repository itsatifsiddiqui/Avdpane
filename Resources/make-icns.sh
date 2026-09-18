#!/bin/bash
# Turns Resources/AppIcon.png into Resources/AppIcon.icns using only built in macOS tools.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
PNG="$DIR/AppIcon.png"
ICONSET="$DIR/AppIcon.iconset"

if [ ! -f "$PNG" ]; then
  swift "$DIR/make-icon.swift"
fi

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# Each size needs a 1x and a 2x file. The 2x file is just the next size up.
for SIZE in 16 32 128 256 512; do
  sips -z "$SIZE" "$SIZE" "$PNG" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
  DOUBLE=$((SIZE * 2))
  sips -z "$DOUBLE" "$DOUBLE" "$PNG" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$DIR/AppIcon.icns"
rm -rf "$ICONSET"
echo "$DIR/AppIcon.icns"
