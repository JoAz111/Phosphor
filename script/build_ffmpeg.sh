#!/usr/bin/env bash
set -euo pipefail

FFMPEG_VERSION="8.1.2"
FFMPEG_SHA256="464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c"
MIN_SYSTEM_VERSION="14.0"

if [[ -d /Applications/Xcode-beta.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
fi

TMP_BASE="${TMPDIR:-/tmp}"
SOURCE_ARCHIVE="${TMP_BASE%/}/ffmpeg-${FFMPEG_VERSION}.tar.xz"
SOURCE_DIR="${TMP_BASE%/}/phosphor-ffmpeg-${FFMPEG_VERSION}-source"
INSTALL_DIR="${TMP_BASE%/}/phosphor-ffmpeg-${FFMPEG_VERSION}-macos14-arm64"

if [[ -f "$INSTALL_DIR/lib/libavformat.a" \
      && -f "$INSTALL_DIR/include/libavformat/avformat.h" ]]; then
  echo "$INSTALL_DIR"
  exit 0
fi

if [[ ! -f "$SOURCE_ARCHIVE" ]]; then
  /usr/bin/curl \
    --fail \
    --location \
    --output "$SOURCE_ARCHIVE" \
    "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"
fi

ACTUAL_SHA256="$(/usr/bin/shasum -a 256 "$SOURCE_ARCHIVE" | /usr/bin/awk '{print $1}')"
if [[ "$ACTUAL_SHA256" != "$FFMPEG_SHA256" ]]; then
  echo "error: FFmpeg source checksum mismatch" >&2
  exit 1
fi

/bin/rm -rf "$SOURCE_DIR" "$INSTALL_DIR"
/bin/mkdir -p "$SOURCE_DIR" "$INSTALL_DIR"
/usr/bin/tar -xf "$SOURCE_ARCHIVE" -C "$SOURCE_DIR" --strip-components=1

export MACOSX_DEPLOYMENT_TARGET="$MIN_SYSTEM_VERSION"
SDK_PATH="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
CLANG_PATH="$(/usr/bin/xcrun --sdk macosx --find clang)"
JOBS="$(/usr/sbin/sysctl -n hw.ncpu)"

cd "$SOURCE_DIR"
./configure \
  --prefix="$INSTALL_DIR" \
  --arch=arm64 \
  --target-os=darwin \
  --cc="$CLANG_PATH" \
  --host-cc="$CLANG_PATH" \
  --host-cflags="-isysroot $SDK_PATH" \
  --sysroot="$SDK_PATH" \
  --extra-cflags="-mmacosx-version-min=$MIN_SYSTEM_VERSION" \
  --extra-ldflags="-mmacosx-version-min=$MIN_SYSTEM_VERSION" \
  --pkg-config=/bin/false \
  --disable-autodetect \
  --disable-programs \
  --disable-doc \
  --disable-debug \
  --disable-network \
  --disable-avdevice \
  --disable-encoders \
  --disable-muxers \
  --disable-filters \
  --disable-shared \
  --enable-static \
  --enable-pic \
  --enable-videotoolbox \
  --enable-audiotoolbox

/usr/bin/make -j"$JOBS"
/usr/bin/make install
/bin/mkdir -p "$INSTALL_DIR/share/licenses/ffmpeg"
/bin/cp "$SOURCE_DIR/COPYING.LGPLv2.1" "$INSTALL_DIR/share/licenses/ffmpeg/"
echo "$INSTALL_DIR"
