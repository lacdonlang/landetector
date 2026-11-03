#!/bin/zsh
# Sets up the secrets the release workflow signs, notarizes and publishes updates with
# (see README ▸ 发布与在线更新). Values go straight to `gh secret set` and are never echoed.
#   1. Sparkle: an EdDSA key pair for LanDetector. The private key stays in the login keychain (account
#      com.lacdon.LanDetector – back it up with the keychain: without it installed copies get no more updates) and
#      goes to SPARKLE_ED_PRIVATE_KEY; the public key is written to project.yml (SUPublicEDKey).
#   2. The "Developer ID Application" certificate, exported from Keychain Access as .p12.
#   3. Notarization: Apple ID and an app-specific password (account.apple.com ▸ 登录与安全 ▸ App 专用密码).
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

print "1/3 Sparkle 更新签名密钥"
if needed SPARKLE_ED_PRIVATE_KEY; then
  tools=build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin
  [[ -x $tools/generate_keys ]] || xcodebuild -resolvePackageDependencies -project LanDetector.xcodeproj \
    -derivedDataPath build/DerivedData > /dev/null
  # Creates the key pair on the first run, then only reads it.
  $tools/generate_keys --account $ACCOUNT -p > /dev/null 2>&1 || $tools/generate_keys --account $ACCOUNT > /dev/null
  public="$($tools/generate_keys --account $ACCOUNT -p)"
  sed -i '' "s|SUPublicEDKey: .*|SUPublicEDKey: $public|" project.yml
  xcodegen generate -q
  print "  公钥 $public 已写入 project.yml"
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' EXIT
  $tools/generate_keys --account $ACCOUNT -x "$dir/key" > /dev/null
  store SPARKLE_ED_PRIVATE_KEY < "$dir/key"
else
  print "  已配置，跳过"
fi

print "\n2/3 Developer ID 证书"
if needed MACOS_CERTIFICATE_P12; then
  print "  在“钥匙串访问”的“登录 ▸ 我的证书”里右键"
  print "  “Developer ID Application: … ($TEAM_ID)” ▸ 导出，存为 .p12 并设置一个密码。"
  read "p12?  .p12 文件路径（可拖入终端）: "
  # Dropped files arrive quoted or backslash-escaped, with a trailing space.
  p12="${${(Q)${${p12## }%% }}/#\~/$HOME}"
  read -s "p12_password?  .p12 密码: "; print
  # A wrong password fails here rather than in CI.
  check="$(mktemp -d)/check.keychain-db"
  security create-keychain -p check "$check"
  security import "$p12" -k "$check" -P "$p12_password" -f pkcs12 > /dev/null
  security delete-keychain "$check"
  base64 -i "$p12" | store MACOS_CERTIFICATE_P12
  print -rn -- "$p12_password" | store MACOS_CERTIFICATE_PASSWORD
  print "  可以删除 $p12 了"
else
  print "  已配置，跳过"
fi

print "\n3/3 公证"
if needed NOTARY_PASSWORD; then
  read "apple_id?  Apple ID: "
  read -s "app_password?  App 专用密码: "; print
  # Fails on wrong credentials.
  xcrun notarytool history --apple-id "$apple_id" --team-id $TEAM_ID --password "$app_password" > /dev/null
  print -rn -- "$apple_id" | store NOTARY_APPLE_ID
  print -rn -- "$TEAM_ID" | store NOTARY_TEAM_ID
  print -rn -- "$app_password" | store NOTARY_PASSWORD
else
  print "  已配置，跳过"
fi

print "\n完成。$REPO 现有的 Secrets："
gh secret list --repo $REPO
git diff --quiet project.yml || print "\nproject.yml 的 SUPublicEDKey 已更新，需要提交。"
