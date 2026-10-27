#!/bin/sh
# Regenerate Resources/AppIcon.icns from scripts/gen-icon.swift.
#   scripts/gen-icon.sh [pulse|nodes|gauge]    (default: pulse)
# Preview all variants at every size with:
#   swift scripts/gen-icon.swift --preview dist/icon && open dist/icon/preview.png
set -eu
cd "$(dirname "$0")/.."
variant=${1:-pulse}
iconset=$(mktemp -d)/AppIcon.iconset
mkdir -p "$iconset"
swift scripts/gen-icon.swift --variant "$variant" --iconset "$iconset"
iconutil -c icns -o Resources/AppIcon.icns "$iconset"
echo "wrote Resources/AppIcon.icns ($variant)"
