#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "usage: $0 <version> <build-number> [notarytool-profile]" >&2
  exit 2
fi

VERSION="$1"
BUILD_NUMBER="$2"
NOTARY_PROFILE="${3:-${PHOSPHOR_NOTARY_PROFILE:-}}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DMG_PATH="$ROOT_DIR/dist/Phosphor-$VERSION.dmg"
APPCAST_PATH="$ROOT_DIR/dist/appcast.xml"
TAG="v$VERSION"

if [[ -z "$NOTARY_PROFILE" ]]; then
  echo "error: publishing requires a notarytool Keychain profile" >&2
  exit 1
fi
if [[ -n "$(/usr/bin/git -C "$ROOT_DIR" status --porcelain)" ]]; then
  echo "error: commit and push the release source before publishing" >&2
  exit 1
fi
if ! /usr/bin/which gh >/dev/null 2>&1; then
  echo "error: GitHub CLI is required to publish a release" >&2
  exit 1
fi
LOCAL_REVISION="$(/usr/bin/git -C "$ROOT_DIR" rev-parse HEAD)"
REMOTE_REVISION="$(
  /usr/bin/git -C "$ROOT_DIR" ls-remote origin refs/heads/main \
    | /usr/bin/awk '{ print $1 }'
)"
if [[ -z "$REMOTE_REVISION" || "$LOCAL_REVISION" != "$REMOTE_REVISION" ]]; then
  echo "error: local HEAD must be pushed to origin/main before publishing" >&2
  exit 1
fi
if /usr/bin/git -C "$ROOT_DIR" show-ref --verify --quiet "refs/tags/$TAG"; then
  echo "error: tag already exists locally: $TAG" >&2
  exit 1
fi
if gh release view "$TAG" --repo JoAz111/Phosphor >/dev/null 2>&1; then
  echo "error: GitHub release already exists: $TAG" >&2
  exit 1
fi

"$ROOT_DIR/script/build_release.sh" \
  "$VERSION" \
  "$BUILD_NUMBER" \
  "$NOTARY_PROFILE"

RELEASE_ARGUMENTS=(
  release create "$TAG"
  "$DMG_PATH#Phosphor $VERSION for Apple silicon"
  "$APPCAST_PATH#Sparkle appcast"
  --repo JoAz111/Phosphor
  --target main
  --title "Phosphor $VERSION"
)
if [[ -n "${PHOSPHOR_RELEASE_NOTES_FILE:-}" ]]; then
  RELEASE_ARGUMENTS+=(--notes-file "$PHOSPHOR_RELEASE_NOTES_FILE")
else
  RELEASE_ARGUMENTS+=(--generate-notes)
fi

gh "${RELEASE_ARGUMENTS[@]}"
echo "Published: https://github.com/JoAz111/Phosphor/releases/tag/$TAG"
