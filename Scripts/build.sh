#!/bin/zsh
# Builds a Release copy of LanDetector.app into ./build/Release.
#   Scripts/build.sh            # build
#   Scripts/build.sh --open     # build and launch
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null && xcodegen generate -q
xcodebuild -project LanDetector.xcodeproj -scheme LanDetector -configuration Release \
  -derivedDataPath build/DerivedData -destination 'platform=macOS' build | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
rm -rf build/Release && mkdir -p build/Release
cp -R build/DerivedData/Build/Products/Release/LanDetector.app build/Release/
codesign --verify --deep --strict build/Release/LanDetector.app && echo "✓ build/Release/LanDetector.app"
[[ "${1:-}" == "--open" ]] && open build/Release/LanDetector.app
exit 0
