#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 <Developer ID Application identity> [notarytool-profile]" >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IDENTITY="$1"
NOTARY_PROFILE="${2:-}"
FFMPEG_PREFIX="$("$ROOT_DIR/script/build_ffmpeg.sh")"
TMP_BASE="${TMPDIR:-/tmp}"
STAGED_APP_BUNDLE="${TMP_BASE%/}/phosphor-swiftpm-build/app-staging/Phosphor.app"

PHOSPHOR_FFMPEG_PREFIX="$FFMPEG_PREFIX" \
  PHOSPHOR_CODESIGN_IDENTITY="$IDENTITY" \
  "$ROOT_DIR/script/build_and_run.sh" --package

APP_BUNDLE="$ROOT_DIR/dist/Phosphor.app"
ARCHIVE="$ROOT_DIR/dist/Phosphor.zip"
if [[ ! -d "$STAGED_APP_BUNDLE" ]]; then
  echo "error: signed staging bundle is missing: $STAGED_APP_BUNDLE" >&2
  exit 1
fi
/bin/rm -f "$ARCHIVE"
/usr/bin/ditto --norsrc --noextattr -c -k --keepParent \
  "$STAGED_APP_BUNDLE" "$ARCHIVE"

if [[ -n "$NOTARY_PROFILE" ]]; then
  /usr/bin/xcrun notarytool submit \
    "$ARCHIVE" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
  /usr/bin/xcrun stapler staple "$STAGED_APP_BUNDLE"
  /bin/rm -f "$ARCHIVE"
  /usr/bin/ditto --norsrc --noextattr -c -k --keepParent \
    "$STAGED_APP_BUNDLE" "$ARCHIVE"
  /bin/rm -rf "$APP_BUNDLE"
  /usr/bin/ditto --norsrc --noextattr "$STAGED_APP_BUNDLE" "$APP_BUNDLE"
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGED_APP_BUNDLE"
/usr/sbin/spctl --assess --type execute --verbose=2 "$STAGED_APP_BUNDLE"
echo "Release artifact: $ARCHIVE"
