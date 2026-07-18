# Phosphor

Phosphor is an open-source macOS video player that reconstructs local video as
a simulated CRT raster. It uses AVFoundation for playback and a native,
multi-pass Metal adaptation of CRT-Guest-Advanced HD for beam reconstruction,
physical-pixel phosphors, bloom, halation, glow, persistence, curvature, and
glass response.

## Requirements

- Apple Silicon Mac
- macOS 14 or later
- Xcode beta command-line tools

## Build

Build, stage, and launch `dist/Phosphor.app` with:

```sh
./script/build_and_run.sh
```

The script prefers Xcode Beta when it is installed and keeps SwiftPM build
artifacts in a deterministic temporary scratch directory. This avoids relying
on workspace `.build` metadata while producing a repeatable app bundle with its
shader and icon resources in `Contents/Resources`.

Run the automated test suite with:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  swift test --scratch-path "${TMPDIR:-/tmp}/phosphor-swiftpm-tests"
```

The run script also supports `--verify`, `--debug`, `--logs`, and `--telemetry`.

## Playback and controls

- Open one local video with File > Open Video, Command-O, drag and drop, or the
  empty-state button.
- Play or pause with the transport button or Space, seek with the timeline,
  adjust volume, and toggle full screen.
- Bypass the CRT treatment, adjust its intensity, or tune curvature, beam
  scanlines, the phosphor mask, tube glow, and vignette in Advanced CRT
  Settings.
- Settings persist locally between launches.

## Current limitations

- Playback is limited to local video formats supported by AVFoundation; there
  is no playlist, media library, or subtitle control in this first pass.
- HDR sources are currently presented through the SDR rendering path, with an
  in-app notice.
- The staged app bundle is intended for local development and is not Developer
  ID signed or notarized for distribution.
- Interactive playback and Metal-frame inspection require a running macOS GUI
  session and are not established by the automated test suite alone.

## License and shader credit

Phosphor is released under the [GNU General Public License, version 2 or any
later version](LICENSE).

Its renderer is a modified Metal/macOS video adaptation of
[CRT-Guest-Advanced HD](https://github.com/libretro/slang-shaders/tree/master/crt/shaders/guest/hd),
copyright (C) 2018-2025 guest(r), with ideas contributed by Dr. Venom and the
Libretro community. The upstream shader and Phosphor's translation are licensed
under GPL-2.0-or-later. Portions of the upstream mask logic originated in
Timothy Lottes' public-domain CRT shader.
