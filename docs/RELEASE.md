# Release and Versioning Guide

This document explains how to publish a new version and keep Sparkle in-app updates working.

## Versioning strategy

Use semantic versioning:

- `MAJOR.MINOR.PATCH`
- Example: `1.0.1`

## Where version lives

macOS app version/build are set in Xcode project build settings:

- `MARKETING_VERSION` -> user-visible version (example `1.0.1`)
- `CURRENT_PROJECT_VERSION` -> build number (example `2`)

Keep Git tag aligned with `MARKETING_VERSION` (`v1.0.1`).

## Sparkle prerequisites (one-time)

1. Generate Sparkle keys:

```bash
./scripts/setup_sparkle_keys.sh
```

2. Ensure app public key is set in target build settings (`INFOPLIST_KEY_SUPublicEDKey`).

3. Confirm feed URL points to:

- `https://raw.githubusercontent.com/daniel-trachtenberg/archive-plugin/main/appcast.xml`

## Pre-release checklist

- Ensure backend starts cleanly.
- Verify onboarding flow.
- Verify search/upload/settings shortcuts.
- Verify LLM cloud/local config in Settings.
- Verify Sparkle `Check for Updates` opens updater UI.

## Publish a release

1. Commit and push final code.

```bash
git push origin main
```

2. Create and push tag (matching app version).

```bash
git tag -a v1.0.1 -m "Release v1.0.1"
git push origin v1.0.1
```

3. Build distributable artifact.

Unsigned flow:

```bash
PREPARE_BACKEND_RUNTIME=1 ./scripts/release_macos.sh
```

Signed/notarized flow:

```bash
PREPARE_BACKEND_RUNTIME=1 \
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="archive-notary" \
./scripts/release_macos.sh
```

Expected artifacts:

- `dist/ArchiveMac-<version>.dmg`
- `dist/ArchiveMac-<version>.dmg.sha256`

With `SPARKLE_ENABLED=1` (default), the script also:

- signs the DMG using Sparkle `sign_update`
- updates `appcast.xml` with the new item

4. Create GitHub release and upload DMG/checksum.

```bash
gh release create v1.0.1 \
  dist/ArchiveMac-1.0.1.dmg \
  dist/ArchiveMac-1.0.1.dmg.sha256 \
  --repo daniel-trachtenberg/archive-plugin \
  --title "v1.0.1" \
  --notes "Release notes here"
```

5. Commit and push updated appcast.

```bash
git add appcast.xml
git commit -m "chore(updates): publish Sparkle appcast for v1.0.1"
git push origin main
```

Important ordering:

- Publish the GitHub release before pushing updated `appcast.xml`.
- This avoids appcast entries pointing to a release asset that does not exist yet.

## Sparkle variables (optional)

`./scripts/release_macos.sh` supports:

- `SPARKLE_ENABLED=0` to skip Sparkle signing/appcast updates
- `SPARKLE_ACCOUNT` keychain account name (default: `archive-plugin`)
- `SPARKLE_REPOSITORY` GitHub repo slug (default: `daniel-trachtenberg/archive-plugin`)
- `SPARKLE_APPCAST_PATH` appcast file path (default: `appcast.xml`)
- `SPARKLE_DOWNLOAD_URL` override enclosure URL
- `SPARKLE_RELEASE_NOTES_URL` override release notes URL
- `SPARKLE_MINIMUM_SYSTEM_VERSION` optional appcast minimum OS attribute

## How in-app updates work now

- App checks feed at `appcast.xml` (not GitHub API polling).
- Sparkle compares `CFBundleVersion` / `CFBundleShortVersionString`.
- If newer update exists, Sparkle downloads and installs it in-app.
- User data/settings remain in user storage (`UserDefaults`, Application Support, backend env/db paths).
