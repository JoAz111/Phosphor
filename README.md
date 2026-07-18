# Phosphor

Phosphor is a first-pass, open-source macOS video player for presenting local
video through a real-time CRT simulation. It uses AVFoundation for playback and
a native Metal renderer for aspect-fitted video, curvature, scanlines, an RGB
mask, glow, and vignette.

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

## First-pass scope and controls

- Open one local video with File > Open Video, Command-O, drag and drop, or the
  empty-state button.
- Play or pause with the transport button or Space, seek with the timeline,
  adjust volume, and toggle full screen.
- Bypass the CRT treatment, adjust its intensity, or tune curvature, scanlines,
  mask, glow, and vignette in Advanced CRT Settings.
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

Phosphor is released under the [MIT License](LICENSE). Its CRT treatment is
informed by Timothy Lottes' public-domain CRT shader; Phosphor's compact Metal
implementation is maintained as native project code.
