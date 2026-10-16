#!/bin/zsh
# Builds landetector-cli and signs it with the Developer ID identity.
# macOS 27 only reveals ARP / NDP neighbour MAC addresses to Developer ID signed processes.
set -euo pipefail
cd "$(dirname "$0")/../Packages/LanDetectorKit"
swift build -c release --product landetector-cli >&2
BIN="$(swift build -c release --show-bin-path)/landetector-cli"
IDENTITY="${LANDETECTOR_SIGN_IDENTITY:-Developer ID Application}"
codesign -f -s "$IDENTITY" "$BIN" >/dev/null 2>&1 || echo "warning: codesign with '$IDENTITY' failed" >&2
exec "$BIN" "$@"
