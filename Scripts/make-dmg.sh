#!/bin/zsh
# Packs LanDetector.app into a compressed disk image with an Applications shortcut to drag it onto.
#   Scripts/make-dmg.sh <LanDetector.app> <output.dmg> [signing identity]
set -euo pipefail
APP="${1:?usage: make-dmg.sh <app> <output.dmg> [identity]}"
DMG="${2:?usage: make-dmg.sh <app> <output.dmg> [identity]}"
IDENTITY="${3:-}"

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
ditto "$APP" "$staging/LanDetector.app"
ln -s /Applications "$staging/Applications"
rm -f "$DMG"
hdiutil create -volname LanDetector -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$DMG" > /dev/null
if [[ -n "$IDENTITY" ]]; then codesign --force --sign "$IDENTITY" --timestamp "$DMG"; fi
echo "✓ $DMG"
