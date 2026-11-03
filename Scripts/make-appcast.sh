#!/bin/zsh
# Writes the Sparkle appcast for one release: a single item, the update zip, signed with the EdDSA private key.
# Installed copies read https://github.com/lacdonlang/landetector/releases/latest/download/appcast.xml – the file of the
# latest (non-pre-release) GitHub release.
#   Scripts/make-appcast.sh <LanDetector.app> <update.zip> <notes.md> <output dir>
# Environment: SPARKLE_ED_PRIVATE_KEY  the private key (`generate_keys -x` output)
#              SIGN_UPDATE             Sparkle's sign_update tool
#              RELEASE_TAG             the tag the zip is published under (default: v<version>)
# Lines of the notes starting with "- " become list items.
set -euo pipefail
APP="${1:?usage: make-appcast.sh <app> <zip> <notes> <output dir>}"
ZIP="${2:?}" NOTES="${3:?}" OUT="${4:?}"
plist() { plutil -extract "$1" raw "$APP/Contents/Info.plist"; }
VERSION="$(plist CFBundleShortVersionString)"
BUILD="$(plist CFBundleVersion)"
MIN_OS="$(plist LSMinimumSystemVersion)"
URL="https://github.com/lacdonlang/landetector/releases/download/${RELEASE_TAG:-v$VERSION}/${ZIP:t}"

SIGNATURE="$(printf '%s' "${SPARKLE_ED_PRIVATE_KEY:?}" | "${SIGN_UPDATE:?}" --ed-key-file - "$ZIP")"
DESCRIPTION="$(sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' "$NOTES" \
  | awk '/^- / { if (!list) print "<ul>"; list = 1; sub(/^- /, ""); print "<li>" $0 "</li>"; next }
         list { print "</ul>"; list = 0 }
         NF { print "<p>" $0 "</p>" }
         END { if (list) print "</ul>" }')"

mkdir -p "$OUT"
cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>LanDetector</title>
    <link>https://github.com/lacdonlang/landetector</link>
    <item>
      <title>LanDetector $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <description><![CDATA[$DESCRIPTION]]></description>
      <enclosure url="$URL" $SIGNATURE type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
echo "✓ $OUT/appcast.xml"
