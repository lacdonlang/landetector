#!/bin/zsh
# Re-signs a built LanDetector.app inside out for distribution. `xcodebuild build` signs the app and
# Sparkle.framework but leaves Sparkle's helpers (XPC services, Autoupdate, Updater.app) ad-hoc signed, which
# notarization rejects.
#   Scripts/resign.sh <LanDetector.app> [identity]     identity defaults to "Developer ID Application"
set -euo pipefail
APP="${1:?usage: resign.sh <LanDetector.app> [identity]}"
IDENTITY="${2:-Developer ID Application}"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"

sign() { codesign --force --sign "$IDENTITY" --options runtime --timestamp --preserve-metadata=entitlements "$@"; }

for helper in "$SPARKLE"/Versions/Current/XPCServices/*.xpc "$SPARKLE/Versions/Current/Autoupdate" \
              "$SPARKLE/Versions/Current/Updater.app"; do
  sign "$helper"
done
sign "$SPARKLE"
sign "$APP"
codesign --verify --deep --strict "$APP"
echo "✓ re-signed $APP"
