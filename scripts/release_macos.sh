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
SPARKLE_ENABLED="${SPARKLE_ENABLED:-1}"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-archive-plugin}"
SPARKLE_REPOSITORY="${SPARKLE_REPOSITORY:-daniel-trachtenberg/archive-plugin}"
SPARKLE_APPCAST_PATH="${SPARKLE_APPCAST_PATH:-$ROOT_DIR/appcast.xml}"
SPARKLE_DOWNLOAD_URL="${SPARKLE_DOWNLOAD_URL:-}"
SPARKLE_RELEASE_NOTES_URL="${SPARKLE_RELEASE_NOTES_URL:-}"
SPARKLE_MINIMUM_SYSTEM_VERSION="${SPARKLE_MINIMUM_SYSTEM_VERSION:-}"
SPARKLE_TOOLS_DIR="${SPARKLE_TOOLS_DIR:-$ROOT_DIR/.sparkle-tools/Sparkle}"

resolve_sparkle_tool() {
  local tool_name="$1"

  if command -v "$tool_name" >/dev/null 2>&1; then
    command -v "$tool_name"
    return 0
  fi

  local candidate="$SPARKLE_TOOLS_DIR/.build/artifacts/sparkle/Sparkle/bin/$tool_name"
  if [[ -x "$candidate" ]]; then
    echo "$candidate"
    return 0
  fi

  if [[ ! -d "$SPARKLE_TOOLS_DIR/.git" ]]; then
    mkdir -p "$(dirname "$SPARKLE_TOOLS_DIR")"
    git clone --depth 1 https://github.com/sparkle-project/Sparkle "$SPARKLE_TOOLS_DIR" >/dev/null 2>&1
  fi

  swift package --package-path "$SPARKLE_TOOLS_DIR" resolve >/dev/null 2>&1

  if [[ ! -x "$candidate" ]]; then
    return 1
  fi

  echo "$candidate"
}

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
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist")

if [[ "$SPARKLE_ENABLED" == "1" ]]; then
  for required_key in SUFeedURL SUPublicEDKey; do
    if ! /usr/libexec/PlistBuddy -c "Print :$required_key" "$APP_PATH/Contents/Info.plist" >/dev/null 2>&1; then
      echo "ERROR: Missing Sparkle Info.plist key '$required_key' in $APP_PATH/Contents/Info.plist" >&2
      echo "Set Sparkle metadata in the app Info.plist before publishing." >&2
      exit 1
    fi
  done
fi

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

if [[ "$SPARKLE_ENABLED" == "1" ]]; then
  if [[ -z "$SPARKLE_DOWNLOAD_URL" ]]; then
    SPARKLE_DOWNLOAD_URL="https://github.com/$SPARKLE_REPOSITORY/releases/download/v${VERSION}/$(basename "$DMG_PATH")"
  fi

  if [[ -z "$SPARKLE_RELEASE_NOTES_URL" ]]; then
    SPARKLE_RELEASE_NOTES_URL="https://github.com/$SPARKLE_REPOSITORY/releases/tag/v${VERSION}"
  fi

  echo "==> Sparkle signing"

  if SIGN_TOOL_PATH="$(resolve_sparkle_tool sign_update)"; then
    if SIGN_OUTPUT="$("$SIGN_TOOL_PATH" --account "$SPARKLE_ACCOUNT" "$DMG_PATH" 2>/dev/null)"; then
      SPARKLE_SIGNATURE="$(echo "$SIGN_OUTPUT" | sed -n 's/.*sparkle:edSignature=\"\\([^\"]*\\)\".*/\\1/p')"
      if [[ -z "$SPARKLE_SIGNATURE" ]]; then
        SPARKLE_SIGNATURE="$(echo "$SIGN_OUTPUT" | sed -n 's/.*edSignature=\"\\([^\"]*\\)\".*/\\1/p')"
      fi

      SPARKLE_LENGTH="$(echo "$SIGN_OUTPUT" | sed -n 's/.*length=\"\\([0-9]*\\)\".*/\\1/p')"
      if [[ -z "$SPARKLE_LENGTH" ]]; then
        SPARKLE_LENGTH="$(echo "$SIGN_OUTPUT" | sed -n 's/.*sparkle:length=\"\\([0-9]*\\)\".*/\\1/p')"
      fi

      if [[ -z "$SPARKLE_SIGNATURE" || -z "$SPARKLE_LENGTH" ]]; then
        echo "WARNING: Could not parse Sparkle signature output. Skipping appcast update." >&2
        echo "Sparkle output: $SIGN_OUTPUT" >&2
      elif [[ ! -x "$ROOT_DIR/scripts/update_sparkle_appcast.py" ]]; then
        echo "WARNING: scripts/update_sparkle_appcast.py is missing. Skipping appcast update." >&2
      else
        "$ROOT_DIR/scripts/update_sparkle_appcast.py" \
          --appcast "$SPARKLE_APPCAST_PATH" \
          --version "$VERSION" \
          --build "$BUILD_NUMBER" \
          --download-url "$SPARKLE_DOWNLOAD_URL" \
          --signature "$SPARKLE_SIGNATURE" \
          --length "$SPARKLE_LENGTH" \
          --release-notes-url "$SPARKLE_RELEASE_NOTES_URL" \
          --minimum-system-version "$SPARKLE_MINIMUM_SYSTEM_VERSION"

        echo "Updated Sparkle appcast: $SPARKLE_APPCAST_PATH"
      fi
    else
      echo "WARNING: Sparkle signing failed for account '$SPARKLE_ACCOUNT'. Run generate_keys first or set SPARKLE_ENABLED=0." >&2
    fi
  else
    echo "WARNING: Could not locate Sparkle sign_update tool. Set SPARKLE_ENABLED=0 to skip." >&2
  fi
fi

echo "Release artifact ready: $DMG_PATH"
