#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Phosphor"
BUNDLE_ID="com.joeyazizoff.Phosphor"
MIN_SYSTEM_VERSION="14.0"

case "$MODE" in
  run|--verify|verify|--debug|debug|--logs|logs|--telemetry|telemetry)
    ;;
  *)
    echo "usage: $0 [--verify|--debug|--logs|--telemetry]" >&2
    exit 2
    ;;
esac

if [[ $# -gt 1 ]]; then
  echo "usage: $0 [--verify|--debug|--logs|--telemetry]" >&2
  exit 2
fi

if [[ -d /Applications/Xcode-beta.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_BASE="${TMPDIR:-/tmp}"
SWIFTPM_SCRATCH_DIR="${TMP_BASE%/}/phosphor-swiftpm-build"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

cd "$ROOT_DIR"

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
  --scratch-path "$SWIFTPM_SCRATCH_DIR" \
  --product "$APP_NAME"
BUILD_BIN_DIR="$(swift build \
  --scratch-path "$SWIFTPM_SCRATCH_DIR" \
  --show-bin-path)"
BUILD_BINARY="$BUILD_BIN_DIR/$APP_NAME"
BUILD_RESOURCE_BUNDLE="$BUILD_BIN_DIR/Phosphor_Phosphor.bundle"
BUILD_ICON="$BUILD_RESOURCE_BUNDLE/Contents/Resources/Phosphor.icns"

for required_path in "$BUILD_BINARY" "$BUILD_RESOURCE_BUNDLE" "$BUILD_ICON"; do
  if [[ ! -e "$required_path" ]]; then
    echo "error: required build artifact is missing: $required_path" >&2
    exit 1
  fi
done

/bin/rm -rf "$APP_BUNDLE"
/bin/mkdir -p "$APP_MACOS" "$APP_RESOURCES"
/bin/cp "$BUILD_BINARY" "$APP_BINARY"
/bin/chmod +x "$APP_BINARY"
/bin/cp -R "$BUILD_RESOURCE_BUNDLE" "$APP_RESOURCES/"
/bin/cp "$BUILD_ICON" "$APP_RESOURCES/Phosphor.icns"

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
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

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
