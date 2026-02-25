# Deployment Guide (macOS Download + Install)

This is the launch path for a direct-download release from your landing page.

## Goal

Users should be able to:

1. Click `Download` on the landing page.
2. Open a `.dmg`.
3. Drag `ArchiveMac.app` into Applications.
4. Launch without Terminal setup.

## Current Foundation in Repo

- The macOS app now uses a shared backend URL source (`BackendService`) instead of hardcoded `localhost:8000`.
- The app starts the backend automatically on launch when it finds `backend/main.py`.
- Backend settings are persisted to a user-writable env file, not the app bundle (`ARCHIVE_ENV_PATH`).
- Runtime builder script: `scripts/build_backend_runtime.sh`.
- Release packager script: `scripts/release_macos.sh`.
- CI release workflow: `.github/workflows/release-macos.yml`.

Backend runtime overrides supported by the app:

- `ARCHIVE_BACKEND_DIR` (path to backend folder containing `main.py`)
- `ARCHIVE_BACKEND_PYTHON` (path to Python executable)
- `ARCHIVE_BACKEND_HOST` / `ARCHIVE_BACKEND_PORT` (API binding)
- `ARCHIVE_BACKEND_SUPPORT_DIR` (writable runtime state directory; defaults under `~/Library/Application Support/ArchivePlugin/backend`)
- `ARCHIVE_ENV_PATH` (custom backend env file path)

## Prerequisites

1. Python 3.10+ available to build backend runtime.
2. Sparkle update key configured (one-time):

```bash
./scripts/setup_sparkle_keys.sh
```

Optional (recommended for smooth install UX):

1. Apple Developer Program membership.
2. Developer ID Application certificate in Keychain.
3. App-specific notarization credentials configured in keychain profile (`xcrun notarytool store-credentials`).

## Build Backend Runtime

From repository root:

```bash
./scripts/build_backend_runtime.sh
```

This creates/updates `backend/.venv` and installs `backend/requirements.txt`.

## Build + Package Command

From repository root (unsigned build):

```bash
PREPARE_BACKEND_RUNTIME=1 ./scripts/release_macos.sh
```

From repository root (Developer ID + notarized build):

```bash
PREPARE_BACKEND_RUNTIME=1 \
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="archive-notary" \
./scripts/release_macos.sh
```

Output:

- Archive: `dist/ArchiveMac.xcarchive`
- DMG: `dist/ArchiveMac-<version>.dmg`
- Checksum file: `dist/ArchiveMac-<version>.dmg.sha256`

Important release-script flags:

- `PREPARE_BACKEND_RUNTIME=1` (default): build backend runtime before packaging
- `REQUIRE_BACKEND_RUNTIME=1` (default): fail packaging if `.venv` is missing
- `NOTARY_KEYCHAIN_PATH=/path/to/keychain-db`: use explicit keychain for notarytool profile
- `SPARKLE_ENABLED=1` (default): sign DMG with Sparkle key and update `appcast.xml`
- `SPARKLE_ACCOUNT=archive-plugin`: Sparkle keychain account to sign updates

## Publish

1. Create Git tag and GitHub Release.
2. Upload `dist/ArchiveMac-<version>.dmg` as a release asset.
3. Add checksum to release notes.
4. Commit/push updated `appcast.xml` after the release is published.
5. Point landing-page button to the latest release asset URL.

## GitHub Actions Automation

Workflow file:

- `.github/workflows/release-macos.yml`

It supports:

1. Manual run (`workflow_dispatch`)
2. Auto-run on GitHub Release publish (`release.published`)

Required GitHub repository secrets:

1. `MACOS_CERTIFICATE_P12_BASE64` (Developer ID Application certificate, base64-encoded `.p12`)
2. `MACOS_CERTIFICATE_PASSWORD` (password for the `.p12`)
3. `MACOS_SIGNING_IDENTITY` (exact signing identity string)
4. `APPLE_ID` (Apple account email for notarization)
5. `APPLE_TEAM_ID` (Apple Developer Team ID)
6. `APPLE_APP_SPECIFIC_PASSWORD` (app-specific password for notarization)

## Critical Launch Checks

1. Test on a clean macOS user account:
   - Download, install, and first launch.
   - Verify onboarding works.
   - Verify search/upload/settings function without manually starting backend.
2. Verify Gatekeeper on the DMG:

```bash
spctl -a -vv --type open dist/ArchiveMac-<version>.dmg
```

3. Verify Sparkle `Check for Updates` offers the latest appcast item.

## Remaining Risk

Backend runtime binaries (for example `torch`) are architecture-specific. If you intend to distribute to both Apple Silicon and Intel Macs, build/test runtime coverage for both targets before launch.
