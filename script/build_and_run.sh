#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Phosphor"
BUNDLE_ID="com.joeyazizoff.Phosphor"
MIN_SYSTEM_VERSION="14.0"
CONFIGURATION="release"
APP_VERSION="${PHOSPHOR_VERSION:-0.1.0}"
APP_BUILD_NUMBER="${PHOSPHOR_BUILD_NUMBER:-1}"
SPARKLE_FEED_URL="https://github.com/JoAz111/Phosphor/releases/latest/download/appcast.xml"
SPARKLE_PUBLIC_ED_KEY="zuRI45WZhuGoRC03nptlqI1ORBNrl2N25s3IJsZZaGA="

if [[ ! "$APP_VERSION" =~ ^[0-9]+([.][0-9]+){1,3}([+-][0-9A-Za-z.-]+)?$ ]]; then
  echo "error: PHOSPHOR_VERSION must be a dotted release version" >&2
  exit 2
fi
if [[ ! "$APP_BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: PHOSPHOR_BUILD_NUMBER must be a positive integer" >&2
  exit 2
fi

case "$MODE" in
  run|--verify|verify|--debug|debug|--logs|logs|--telemetry|telemetry|--package|package)
    ;;
  *)
    echo "usage: $0 [--verify|--debug|--logs|--telemetry|--package]" >&2
    exit 2
    ;;
esac

if [[ "$MODE" == "--debug" || "$MODE" == "debug" ]]; then
  CONFIGURATION="debug"
fi

if [[ $# -gt 1 ]]; then
  echo "usage: $0 [--verify|--debug|--logs|--telemetry|--package]" >&2
  exit 2
fi

if [[ -d /Applications/Xcode-beta.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
fi
export COPYFILE_DISABLE=1

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_BASE="${TMPDIR:-/tmp}"
SWIFTPM_SCRATCH_DIR="${TMP_BASE%/}/phosphor-swiftpm-build"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
STAGING_DIR="$SWIFTPM_SCRATCH_DIR/app-staging"
STAGED_APP_BUNDLE="$STAGING_DIR/$APP_NAME.app"
APP_CONTENTS="$STAGED_APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
FFMPEG_PREFIX="${PHOSPHOR_FFMPEG_PREFIX:-/opt/homebrew/opt/ffmpeg}"

cd "$ROOT_DIR"

if ! /usr/bin/xcrun -sdk macosx metal --version >/dev/null 2>&1; then
  echo "error: Xcode's Metal compiler component is not installed." >&2
  echo "install it with: xcodebuild -downloadComponent MetalToolchain" >&2
  exit 1
fi

/usr/bin/pkill -x "$APP_NAME" >/dev/null 2>&1 || true
for _ in {1..20}; do
  if ! /usr/bin/pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
if /usr/bin/pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  echo "error: $APP_NAME did not stop" >&2
  exit 1
fi

swift build \
  --configuration "$CONFIGURATION" \
  --scratch-path "$SWIFTPM_SCRATCH_DIR" \
  --product "$APP_NAME"
BUILD_BIN_DIR="$(swift build \
  --configuration "$CONFIGURATION" \
  --scratch-path "$SWIFTPM_SCRATCH_DIR" \
  --show-bin-path)"
BUILD_BINARY="$BUILD_BIN_DIR/$APP_NAME"
BUILD_RESOURCE_BUNDLE="$BUILD_BIN_DIR/Phosphor_Phosphor.bundle"
BUILD_ICON="$BUILD_RESOURCE_BUNDLE/Contents/Resources/Phosphor.icns"
BUILD_SPARKLE_FRAMEWORK="$BUILD_BIN_DIR/Sparkle.framework"
if [[ ! -d "$BUILD_SPARKLE_FRAMEWORK" ]]; then
  BUILD_SPARKLE_FRAMEWORK="$BUILD_BIN_DIR/PackageFrameworks/Sparkle.framework"
fi
PROJECT_LICENSE="$ROOT_DIR/LICENSE"
SPARKLE_DISTRIBUTION="$SWIFTPM_SCRATCH_DIR/artifacts/sparkle/Sparkle"
if [[ ! -d "$SPARKLE_DISTRIBUTION" ]]; then
  SPARKLE_DISTRIBUTION="$ROOT_DIR/.build/artifacts/sparkle/Sparkle"
fi
SPARKLE_LICENSE="$SPARKLE_DISTRIBUTION/LICENSE"
METAL_SOURCE="$ROOT_DIR/Sources/Phosphor/Resources/PhosphorShaders.metal"
METAL_AIR="$SWIFTPM_SCRATCH_DIR/PhosphorShaders.air"
METAL_LIBRARY="$APP_RESOURCES/Phosphor_Phosphor.bundle/Contents/Resources/PhosphorShaders.metallib"

for required_path in \
  "$BUILD_BINARY" \
  "$BUILD_RESOURCE_BUNDLE" \
  "$BUILD_ICON" \
  "$BUILD_SPARKLE_FRAMEWORK" \
  "$PROJECT_LICENSE" \
  "$SPARKLE_LICENSE"; do
  if [[ ! -e "$required_path" ]]; then
    echo "error: required build artifact is missing: $required_path" >&2
    exit 1
  fi
done

/bin/rm -rf "$STAGED_APP_BUNDLE"
/bin/mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$APP_FRAMEWORKS"
/bin/cp "$BUILD_BINARY" "$APP_BINARY"
/bin/chmod +x "$APP_BINARY"
/bin/cp -R "$BUILD_RESOURCE_BUNDLE" "$APP_RESOURCES/"
/bin/cp "$BUILD_ICON" "$APP_RESOURCES/Phosphor.icns"
/bin/cp "$PROJECT_LICENSE" "$APP_RESOURCES/COPYING"
/usr/bin/ditto --norsrc --noextattr \
  "$BUILD_SPARKLE_FRAMEWORK" \
  "$APP_FRAMEWORKS/Sparkle.framework"
/bin/mkdir -p "$APP_RESOURCES/ThirdParty/Sparkle"
/bin/cp "$SPARKLE_LICENSE" "$APP_RESOURCES/ThirdParty/Sparkle/LICENSE"
if [[ -d "$FFMPEG_PREFIX/share/licenses/ffmpeg" ]]; then
  /bin/mkdir -p "$APP_RESOURCES/ThirdParty/FFmpeg"
  /bin/cp -R "$FFMPEG_PREFIX/share/licenses/ffmpeg/." \
    "$APP_RESOURCES/ThirdParty/FFmpeg/"
fi
"$ROOT_DIR/script/bundle_dylibs.sh" "$APP_BINARY" "$APP_FRAMEWORKS"

/usr/bin/xcrun -sdk macosx metal \
  -ffast-math \
  -c "$METAL_SOURCE" \
  -o "$METAL_AIR"
/usr/bin/xcrun -sdk macosx metallib \
  "$METAL_AIR" \
  -o "$METAL_LIBRARY"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>Phosphor</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD_NUMBER</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>
      <string>Video</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.movie</string>
        <string>public.audiovisual-content</string>
      </array>
      <key>CFBundleTypeExtensions</key>
      <array>
        <string>mp4</string>
        <string>mov</string>
        <string>m4v</string>
        <string>mkv</string>
        <string>avi</string>
        <string>webm</string>
        <string>mpg</string>
        <string>mpeg</string>
        <string>ts</string>
        <string>m2ts</string>
        <string>wmv</string>
        <string>flv</string>
      </array>
    </dict>
  </array>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>SUFeedURL</key>
  <string>$SPARKLE_FEED_URL</string>
  <key>SUPublicEDKey</key>
  <string>$SPARKLE_PUBLIC_ED_KEY</string>
  <key>SUVerifyUpdateBeforeExtraction</key>
  <true/>
</dict>
</plist>
PLIST

SIGNING_IDENTITY="${PHOSPHOR_CODESIGN_IDENTITY:--}"
SIGNING_ARGUMENTS=(--force --sign "$SIGNING_IDENTITY")
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  SIGNING_ARGUMENTS+=(--timestamp=none)
else
  SIGNING_ARGUMENTS+=(--options runtime --timestamp)
fi

/usr/bin/xattr -cr "$STAGED_APP_BUNDLE"

# Sparkle contains executable helpers inside its versioned framework. Sign it
# inside-out exactly as Sparkle requires; --deep is intentionally not used.
SPARKLE_FRAMEWORK="$APP_FRAMEWORKS/Sparkle.framework"
SPARKLE_VERSION_DIR="$SPARKLE_FRAMEWORK/Versions/Current"
if [[ -d "$SPARKLE_VERSION_DIR/XPCServices/Installer.xpc" ]]; then
  /usr/bin/codesign "${SIGNING_ARGUMENTS[@]}" \
    "$SPARKLE_VERSION_DIR/XPCServices/Installer.xpc"
fi
if [[ -d "$SPARKLE_VERSION_DIR/XPCServices/Downloader.xpc" ]]; then
  /usr/bin/codesign "${SIGNING_ARGUMENTS[@]}" \
    --preserve-metadata=entitlements \
    "$SPARKLE_VERSION_DIR/XPCServices/Downloader.xpc"
fi
/usr/bin/codesign "${SIGNING_ARGUMENTS[@]}" \
  "$SPARKLE_VERSION_DIR/Autoupdate"
/usr/bin/codesign "${SIGNING_ARGUMENTS[@]}" \
  "$SPARKLE_VERSION_DIR/Updater.app"
/usr/bin/codesign "${SIGNING_ARGUMENTS[@]}" "$SPARKLE_FRAMEWORK"

while IFS= read -r nested_binary; do
  /usr/bin/codesign "${SIGNING_ARGUMENTS[@]}" "$nested_binary"
done < <(/usr/bin/find "$APP_FRAMEWORKS" -type f -name '*.dylib' -print)
/usr/bin/codesign "${SIGNING_ARGUMENTS[@]}" "$STAGED_APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict "$STAGED_APP_BUNDLE"

if [[ "$MODE" != "--package" && "$MODE" != "package" ]]; then
  /bin/mkdir -p "$DIST_DIR"
  /bin/rm -rf "$APP_BUNDLE"
  # Sign before copying into a File Provider-backed workspace. File Provider
  # can attach Finder metadata after the copy even though the sealed files are
  # intact. Release packaging consumes the pristine staging bundle directly.
  /usr/bin/ditto --norsrc --noextattr "$STAGED_APP_BUNDLE" "$APP_BUNDLE"
  /usr/bin/xattr -cr "$APP_BUNDLE"
  /usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
fi

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

wait_for_process() {
  local process_id

  for _ in {1..40}; do
    process_id="$(/usr/bin/pgrep -x "$APP_NAME" | /usr/bin/head -n 1 || true)"
    if [[ -n "$process_id" ]]; then
      echo "$process_id"
      return 0
    fi
    sleep 0.1
  done

  echo "error: $APP_NAME did not launch" >&2
  return 1
}

case "$MODE" in
  --package|package)
    echo "$STAGED_APP_BUNDLE"
    ;;
  run)
    open_app
    ;;
  --verify|verify)
    open_app
    wait_for_process >/dev/null
    echo "$APP_NAME is running from $APP_BUNDLE"
    ;;
  --debug|debug)
    open_app
    APP_PID="$(wait_for_process)"
    exec /usr/bin/lldb -p "$APP_PID"
    ;;
  --logs|logs)
    open_app
    wait_for_process >/dev/null
    exec /usr/bin/log stream \
      --info \
      --style compact \
      --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    wait_for_process >/dev/null
    exec /usr/bin/log stream \
      --info \
      --style compact \
      --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
esac
