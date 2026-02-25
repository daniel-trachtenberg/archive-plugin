#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
PROJECT_PATH="${PROJECT_PATH:-$ROOT_DIR/ArchiveMac/ArchiveMac.xcodeproj}"
SCHEME="${SCHEME:-ArchiveMac}"
CONFIGURATION="${CONFIGURATION:-Release}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$DIST_DIR/ArchiveMac.xcarchive}"
APP_NAME="${APP_NAME:-ArchiveMac.app}"
APP_PATH="$ARCHIVE_PATH/Products/Applications/$APP_NAME"
BACKEND_SRC_DIR="${BACKEND_SRC_DIR:-$ROOT_DIR/backend}"
BACKEND_DEST_DIR="$APP_PATH/Contents/Resources/backend"
PREPARE_BACKEND_RUNTIME="${PREPARE_BACKEND_RUNTIME:-1}"
BACKEND_RUNTIME_PYTHON="${BACKEND_RUNTIME_PYTHON:-python3}"
REQUIRE_BACKEND_RUNTIME="${REQUIRE_BACKEND_RUNTIME:-1}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
NOTARY_KEYCHAIN_PATH="${NOTARY_KEYCHAIN_PATH:-}"

mkdir -p "$DIST_DIR"
rm -rf "$ARCHIVE_PATH"

echo "==> Archiving macOS app"
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=macOS" \
  -archivePath "$ARCHIVE_PATH" \
  archive

if [[ ! -d "$APP_PATH" ]]; then
  echo "Archive did not produce app at: $APP_PATH" >&2
  exit 1
fi

if [[ ! -d "$BACKEND_SRC_DIR" ]]; then
  echo "Backend source directory not found: $BACKEND_SRC_DIR" >&2
  exit 1
fi

if [[ "$PREPARE_BACKEND_RUNTIME" == "1" ]]; then
  echo "==> Preparing backend runtime"
  BACKEND_DIR="$BACKEND_SRC_DIR" \
    PYTHON_BIN="$BACKEND_RUNTIME_PYTHON" \
    "$ROOT_DIR/scripts/build_backend_runtime.sh"
fi

echo "==> Bundling backend into app resources"
rm -rf "$BACKEND_DEST_DIR"
mkdir -p "$BACKEND_DEST_DIR"
rsync -a \
  --exclude "__pycache__/" \
  --exclude "*.pyc" \
  --exclude ".pytest_cache/" \
  --exclude ".mypy_cache/" \
  --exclude ".DS_Store" \
  --exclude ".env" \
  --exclude ".env.*" \
  "$BACKEND_SRC_DIR/" \
  "$BACKEND_DEST_DIR/"

if [[ ! -x "$BACKEND_DEST_DIR/.venv/bin/python3" && ! -x "$BACKEND_DEST_DIR/.venv/bin/python" ]]; then
  message="No bundled backend virtualenv detected at backend/.venv/bin/python3."
  if [[ "$REQUIRE_BACKEND_RUNTIME" == "1" ]]; then
    echo "ERROR: $message" >&2
    echo "Set REQUIRE_BACKEND_RUNTIME=0 to bypass this check." >&2
    exit 1
  else
    cat <<'WARN'
WARNING: No bundled backend virtualenv detected at backend/.venv/bin/python3.
The app can still work if the user already has compatible Python dependencies installed,
but for one-click installs you should bundle a prepared backend .venv.
WARN
  fi
fi

if [[ -n "$SIGNING_IDENTITY" ]]; then
  echo "==> Signing app with identity: $SIGNING_IDENTITY"
  codesign --force --deep --options runtime --sign "$SIGNING_IDENTITY" "$APP_PATH"
else
  echo "==> Re-signing app ad-hoc for unsigned distribution"
  codesign --force --deep --sign - "$APP_PATH"
fi

echo "==> Verifying app signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
DMG_PATH="${DMG_PATH:-$DIST_DIR/ArchiveMac-${VERSION}.dmg}"
DMG_STAGING_DIR="$DIST_DIR/dmg-staging"
DMG_VOLUME_NAME="${DMG_VOLUME_NAME:-Archive Plugin}"
DMG_ICON_ICNS="${DMG_ICON_ICNS:-$ROOT_DIR/branding/ArchiveVolume.icns}"
DMG_RW_PATH="$DIST_DIR/ArchiveMac-${VERSION}-rw.dmg"
DMG_MOUNTPOINT="$DIST_DIR/dmg-mount"

rm -rf "$DMG_STAGING_DIR"
mkdir -p "$DMG_STAGING_DIR"
cp -R "$APP_PATH" "$DMG_STAGING_DIR/"

echo "==> Creating writable DMG"
rm -f "$DMG_PATH" "$DMG_RW_PATH"
hdiutil create -volname "$DMG_VOLUME_NAME" -srcfolder "$DMG_STAGING_DIR" -ov -format UDRW "$DMG_RW_PATH"

echo "==> Applying DMG volume icon"
rm -rf "$DMG_MOUNTPOINT"
mkdir -p "$DMG_MOUNTPOINT"
hdiutil attach "$DMG_RW_PATH" -mountpoint "$DMG_MOUNTPOINT" -nobrowse -quiet

if [[ -f "$DMG_ICON_ICNS" ]]; then
  cp "$DMG_ICON_ICNS" "$DMG_MOUNTPOINT/.VolumeIcon.icns"
  if command -v SetFile >/dev/null; then
    SetFile -a V "$DMG_MOUNTPOINT/.VolumeIcon.icns"
    SetFile -a C "$DMG_MOUNTPOINT"
  else
    echo "WARNING: SetFile not found; DMG volume icon may not be applied." >&2
  fi
else
  echo "WARNING: DMG icon not found at $DMG_ICON_ICNS; using default volume icon." >&2
fi

hdiutil detach "$DMG_MOUNTPOINT" -quiet
rmdir "$DMG_MOUNTPOINT"

echo "==> Creating compressed DMG: $DMG_PATH"
hdiutil convert "$DMG_RW_PATH" -format UDZO -o "$DMG_PATH" -ov
rm -f "$DMG_RW_PATH"

if [[ -n "$NOTARY_PROFILE" ]]; then
  echo "==> Notarizing DMG with keychain profile: $NOTARY_PROFILE"
  notary_keychain_args=()
  if [[ -n "$NOTARY_KEYCHAIN_PATH" ]]; then
    notary_keychain_args+=(--keychain "$NOTARY_KEYCHAIN_PATH")
  fi

  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" "${notary_keychain_args[@]}" --wait
  echo "==> Stapling notarization ticket"
  xcrun stapler staple "$DMG_PATH"
else
  echo "==> Skipping notarization (NOTARY_PROFILE not set)"
fi

echo "==> SHA256"
shasum -a 256 "$DMG_PATH" | tee "${DMG_PATH}.sha256"

echo "Release artifact ready: $DMG_PATH"
