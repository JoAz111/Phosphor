#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "usage: $0 <version> <build-number> [notarytool-profile]" >&2
  exit 2
fi

VERSION="$1"
BUILD_NUMBER="$2"
NOTARY_PROFILE="${3:-${PHOSPHOR_NOTARY_PROFILE:-}}"
APP_NAME="Phosphor"
REPOSITORY_URL="https://github.com/JoAz111/Phosphor"
RELEASE_TAG="v$VERSION"

if [[ ! "$VERSION" =~ ^[0-9]+([.][0-9]+){1,3}([+-][0-9A-Za-z.-]+)?$ ]]; then
  echo "error: version must be a dotted release version" >&2
  exit 2
fi
if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: build-number must be a positive integer" >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_BASE="${TMPDIR:-/tmp}"
SWIFTPM_SCRATCH_DIR="${TMP_BASE%/}/phosphor-swiftpm-build"
STAGED_APP_BUNDLE="$SWIFTPM_SCRATCH_DIR/app-staging/$APP_NAME.app"
DIST_DIR="$ROOT_DIR/dist"
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"
APPCAST_PATH="$DIST_DIR/appcast.xml"
WORK_DIR="$(/usr/bin/mktemp -d "${TMP_BASE%/}/phosphor-release.XXXXXX")"
DMG_ROOT="$WORK_DIR/dmg-root"
MOUNT_POINT="$WORK_DIR/mount"
UPDATE_DIR="$WORK_DIR/updates"
MOUNTED=0

cleanup() {
  if [[ "$MOUNTED" == 1 ]]; then
    /usr/bin/hdiutil detach "$MOUNT_POINT" -quiet || true
  fi
  /bin/rm -rf "$WORK_DIR"
}
trap cleanup EXIT

IDENTITY="${PHOSPHOR_CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(
    /usr/bin/security find-identity -p codesigning -v \
      | /usr/bin/awk -F '"' '/Developer ID Application:/ { print $2; exit }'
  )"
fi
if [[ "$IDENTITY" != "Developer ID Application:"* ]]; then
  echo "error: no Developer ID Application identity is available" >&2
  exit 1
fi
if ! /usr/bin/security find-identity -p codesigning -v \
    | /usr/bin/grep -Fq "\"$IDENTITY\""; then
  echo "error: signing identity is not valid: $IDENTITY" >&2
  exit 1
fi

FFMPEG_PREFIX="$("$ROOT_DIR/script/build_ffmpeg.sh")"
PHOSPHOR_VERSION="$VERSION" \
  PHOSPHOR_BUILD_NUMBER="$BUILD_NUMBER" \
  PHOSPHOR_FFMPEG_PREFIX="$FFMPEG_PREFIX" \
  PHOSPHOR_CODESIGN_IDENTITY="$IDENTITY" \
  "$ROOT_DIR/script/build_and_run.sh" --package

if [[ ! -d "$STAGED_APP_BUNDLE" ]]; then
  echo "error: signed staging bundle is missing: $STAGED_APP_BUNDLE" >&2
  exit 1
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGED_APP_BUNDLE"
/bin/mkdir -p "$DIST_DIR" "$DMG_ROOT" "$MOUNT_POINT" "$UPDATE_DIR"
/usr/bin/ditto --norsrc --noextattr \
  "$STAGED_APP_BUNDLE" "$DMG_ROOT/$APP_NAME.app"
/bin/ln -s /Applications "$DMG_ROOT/Applications"

/bin/rm -f "$DMG_PATH" "$APPCAST_PATH"
/usr/bin/hdiutil create \
  -quiet \
  -volname "$APP_NAME" \
  -fs APFS \
  -format ULFO \
  -srcfolder "$DMG_ROOT" \
  "$DMG_PATH"
/usr/bin/codesign \
  --force \
  --sign "$IDENTITY" \
  --timestamp \
  "$DMG_PATH"
/usr/bin/hdiutil verify "$DMG_PATH"

if [[ -n "$NOTARY_PROFILE" ]]; then
  /usr/bin/xcrun notarytool submit \
    "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
  /usr/bin/xcrun stapler staple "$DMG_PATH"
  /usr/bin/xcrun stapler validate "$DMG_PATH"
  /usr/sbin/spctl --assess \
    --type open \
    --context context:primary-signature \
    --verbose=2 \
    "$DMG_PATH"
else
  echo "warning: DMG is Developer ID signed but not notarized" >&2
  echo "warning: pass a notarytool Keychain profile before publishing" >&2
fi

/usr/bin/hdiutil attach \
  "$DMG_PATH" \
  -quiet \
  -nobrowse \
  -readonly \
  -mountpoint "$MOUNT_POINT"
MOUNTED=1
/usr/bin/codesign --verify \
  --deep \
  --strict \
  --verbose=2 \
  "$MOUNT_POINT/$APP_NAME.app"
if [[ -n "$NOTARY_PROFILE" ]]; then
  /usr/sbin/spctl --assess \
    --type execute \
    --verbose=2 \
    "$MOUNT_POINT/$APP_NAME.app"
fi
/usr/bin/hdiutil detach "$MOUNT_POINT" -quiet
MOUNTED=0

SPARKLE_DISTRIBUTION="$SWIFTPM_SCRATCH_DIR/artifacts/sparkle/Sparkle"
if [[ ! -d "$SPARKLE_DISTRIBUTION" ]]; then
  SPARKLE_DISTRIBUTION="$ROOT_DIR/.build/artifacts/sparkle/Sparkle"
fi
GENERATE_APPCAST="$SPARKLE_DISTRIBUTION/bin/generate_appcast"
if [[ ! -x "$GENERATE_APPCAST" ]]; then
  echo "error: Sparkle generate_appcast tool is missing" >&2
  exit 1
fi

/usr/bin/ditto --norsrc --noextattr "$DMG_PATH" "$UPDATE_DIR/$(/usr/bin/basename "$DMG_PATH")"
"$GENERATE_APPCAST" \
  --download-url-prefix "$REPOSITORY_URL/releases/download/$RELEASE_TAG/" \
  --link "$REPOSITORY_URL" \
  --versions "$BUILD_NUMBER" \
  --maximum-versions 3 \
  -o "$APPCAST_PATH" \
  "$UPDATE_DIR"
/usr/bin/xmllint --noout "$APPCAST_PATH"

if ! /usr/bin/grep -Fq "$RELEASE_TAG/$(/usr/bin/basename "$DMG_PATH")" "$APPCAST_PATH"; then
  echo "error: generated appcast does not reference the release DMG" >&2
  exit 1
fi
if ! /usr/bin/grep -Fq 'sparkle:edSignature=' "$APPCAST_PATH"; then
  echo "error: generated appcast is missing its EdDSA update signature" >&2
  exit 1
fi

echo "Release app: $STAGED_APP_BUNDLE"
echo "Release DMG: $DMG_PATH"
echo "Sparkle appcast: $APPCAST_PATH"
if [[ -n "$NOTARY_PROFILE" ]]; then
  echo "Notarization: accepted and stapled"
else
  echo "Notarization: not submitted"
fi
