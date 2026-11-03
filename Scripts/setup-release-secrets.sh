#!/bin/zsh
# Sets up the secrets the release workflow signs, notarizes and publishes updates with
# (see docs/en/RELEASING.md). Values go straight to `gh secret set` and are never echoed.
#   1. Sparkle: an EdDSA key pair for LanDetector. The private key stays in the login keychain (account
#      com.lacdon.LanDetector – back it up with the keychain: without it installed copies get no more updates) and
#      goes to SPARKLE_ED_PRIVATE_KEY; the public key is written to project.yml (SUPublicEDKey).
#   2. The "Developer ID Application" certificate, exported from Keychain Access as .p12.
#   3. Notarization: Apple ID and an app-specific password (account.apple.com ▸ Sign-In and Security ▸ App-Specific Passwords).
# Steps whose secrets already exist are skipped; FORCE=1 redoes them.
#   Scripts/setup-release-secrets.sh
set -euo pipefail
cd "$(dirname "$0")/.."
REPO=lacdonlang/landetector
TEAM_ID=N4828PE57J
ACCOUNT=com.lacdon.LanDetector

existing="$(gh secret list --repo $REPO --json name --jq '.[].name')"
needed() { [[ -n "${FORCE:-}" ]] || ! print -r -- "$existing" | grep -qx "$1"; }
store() { gh secret set "$1" --repo $REPO > /dev/null && print "  ✓ $1"; }   # value on stdin

print "1/3 Sparkle update signing key"
if needed SPARKLE_ED_PRIVATE_KEY; then
  tools=build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin
  [[ -x $tools/generate_keys ]] || xcodebuild -resolvePackageDependencies -project LanDetector.xcodeproj \
    -derivedDataPath build/DerivedData > /dev/null
  # Creates the key pair on the first run, then only reads it.
  $tools/generate_keys --account $ACCOUNT -p > /dev/null 2>&1 || $tools/generate_keys --account $ACCOUNT > /dev/null
  public="$($tools/generate_keys --account $ACCOUNT -p)"
  sed -i '' "s|SUPublicEDKey: .*|SUPublicEDKey: $public|" project.yml
  xcodegen generate -q
  print "  Public key $public written to project.yml"
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' EXIT
  $tools/generate_keys --account $ACCOUNT -x "$dir/key" > /dev/null
  store SPARKLE_ED_PRIVATE_KEY < "$dir/key"
else
  print "  Already set, skipped"
fi

print "\n2/3 Developer ID certificate"
if needed MACOS_CERTIFICATE_P12; then
  print "  In Keychain Access ▸ login ▸ My Certificates, Control-click"
  print "  “Developer ID Application: … ($TEAM_ID)” ▸ Export, save it as .p12 and set a password."
  read "p12?  Path of the .p12 (drag it into the terminal): "
  # Dropped files arrive quoted or backslash-escaped, with a trailing space.
  p12="${${(Q)${${p12## }%% }}/#\~/$HOME}"
  read -s "p12_password?  Password of the .p12: "; print
  # A wrong password fails here rather than in CI.
  check="$(mktemp -d)/check.keychain-db"
  security create-keychain -p check "$check"
  security import "$p12" -k "$check" -P "$p12_password" -f pkcs12 > /dev/null
  security delete-keychain "$check"
  base64 -i "$p12" | store MACOS_CERTIFICATE_P12
  print -rn -- "$p12_password" | store MACOS_CERTIFICATE_PASSWORD
  print "  You can delete $p12 now."
else
  print "  Already set, skipped"
fi

print "\n3/3 Notarization"
if needed NOTARY_PASSWORD; then
  read "apple_id?  Apple ID: "
  read -s "app_password?  App-specific password: "; print
  # Fails on wrong credentials.
  xcrun notarytool history --apple-id "$apple_id" --team-id $TEAM_ID --password "$app_password" > /dev/null
  print -rn -- "$apple_id" | store NOTARY_APPLE_ID
  print -rn -- "$TEAM_ID" | store NOTARY_TEAM_ID
  print -rn -- "$app_password" | store NOTARY_PASSWORD
else
  print "  Already set, skipped"
fi

print "\nDone. Secrets of $REPO:"
gh secret list --repo $REPO
git diff --quiet project.yml || print "\nSUPublicEDKey in project.yml changed: commit it."
