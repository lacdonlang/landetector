#!/bin/zsh
# README screenshots: the Debug build shows a made-up network (LANDETECTOR_DEMO) and captures its main window in each
# language and appearance into docs/images/<language>/<appearance>/. Capturing needs the Screen Recording permission for
# the Debug LanDetector app (System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording).
#   Scripts/screenshots.sh [path/to/Debug/LanDetector.app]
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:-build/DerivedData/Build/Products/Debug/LanDetector.app}"
DOMAIN=com.lacdon.LanDetector

# The run switches between list and card view, which the app remembers.
view_mode="$(defaults read $DOMAIN viewMode 2> /dev/null || true)"
restore() { if [[ -n "$view_mode" ]]; then defaults write $DOMAIN viewMode "$view_mode"; fi; }
trap restore EXIT

for language in en zh-Hans; do
  folder=${${language/zh-Hans/zh-CN}}
  for appearance in light dark; do
    LANDETECTOR_DEMO=1 LANDETECTOR_APPEARANCE=$appearance LANDETECTOR_SCREENSHOTS="docs/images/$folder/$appearance" \
      "$APP/Contents/MacOS/LanDetector" -AppleLanguages "($language)" -selectedRangePreset "" \
      -ApplePersistenceIgnoreState YES
  done
done
find docs/images -name "*.jpg" | sort
