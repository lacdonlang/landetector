# Releasing

**English** · [简体中文](../zh-CN/RELEASING.md)

LanDetector is distributed outside the App Store, signed with a Developer ID and notarized: macOS 27 only shows ARP / NDP MAC addresses to Developer ID signed apps.

## Publishing a version

Push a tag starting with `v`. Its message becomes the release notes, both on the release page and in the update window; lines starting with `- ` are shown as a list.

```bash
git tag -a v1.2.0 -m "- New feature" -m "- Fix"
```

```bash
git push origin v1.2.0
```

[`.github/workflows/release.yml`](../../.github/workflows/release.yml) then runs on the `xcode-27` runner:

1. Runs the LanDetectorKit tests.
2. Builds a universal (Apple silicon + Intel) Release, with the version from the tag and the build number derived from it (1.2.3 → 10203).
3. Re-signs Sparkle's helpers and the app inside out with the Developer ID (`Scripts/resign.sh`; `xcodebuild build` leaves the helpers ad-hoc signed).
4. Notarizes and staples the app, then packs `LanDetector-<version>.zip` (for updates) and `LanDetector-<version>.dmg` (for downloads, `Scripts/make-dmg.sh`), and notarizes and staples the disk image.
5. Signs the zip with the EdDSA key and writes `appcast.xml` (`Scripts/make-appcast.sh`).
6. Publishes the GitHub release with the DMG, the zip, `SHA256SUMS.txt` and `appcast.xml`.

A tag with a suffix, such as `v1.2.0-beta.1`, becomes a pre-release, which installed copies don't see. Running the workflow by hand from the Actions page builds the same files as a workflow artifact and publishes nothing – use it to check a change to the pipeline.

## Updates

Installed copies use [Sparkle](https://sparkle-project.org) to read `https://github.com/lacdonlang/landetector/releases/latest/download/appcast.xml` once a day (or on LanDetector ▸ Check for Updates…). An update is installed only if the zip's EdDSA signature matches `SUPublicEDKey` in `project.yml` and the new app is signed by the same team. Debug builds never check. The repository must stay public so the app can download updates anonymously.

## Secrets

The repository secrets have the same names as Fidget's. `Scripts/setup-release-secrets.sh` sets them up interactively and skips the ones that already exist (`FORCE=1` redoes them):

| Secret | Contents |
| --- | --- |
| `MACOS_CERTIFICATE_P12`, `MACOS_CERTIFICATE_PASSWORD` | The `Developer ID Application` certificate with its private key, exported from Keychain Access as .p12 (base64), and its password |
| `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, `NOTARY_PASSWORD` | The Apple ID, team ID and an app-specific password for notarization |
| `SPARKLE_ED_PRIVATE_KEY` | The EdDSA private key that signs updates |

The Sparkle private key also stays in the maintainer's login keychain (account `com.lacdon.LanDetector`). **Back it up with the keychain**: without it, installed copies can never be updated again, because new signatures would not match their built-in public key.

Without the certificate the workflow builds an ad-hoc signed app (without the hardened runtime, which would refuse Sparkle) and no appcast; without the notarization secrets it skips notarization.

## Checking a build

```bash
codesign -dv --verbose=4 LanDetector.app
```

```bash
spctl --assess --type execute -vv LanDetector.app
```

```bash
xcrun stapler validate LanDetector.dmg
```
