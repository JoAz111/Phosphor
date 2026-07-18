# Phosphor

**A native macOS video player that rebuilds every frame as light on a CRT.**

Phosphor plays local video through a real-time Metal rendering graph inspired by
[CRT-Guest-Advanced HD](https://github.com/libretro/slang-shaders/tree/master/crt/shaders/guest/hd).
Instead of placing a scanline texture over the picture, it reconstructs a virtual
electron-beam raster, changes beam width with luminance, maps the result onto
discrete RGB phosphors, and models the light that spreads through the phosphor
layer and curved glass.

Phosphor is free software under **GPL-2.0-or-later**.

> [!IMPORTANT]
> Phosphor is an early preview. The current renderer ports Guest Advanced HD's
> default progressive signal path to native Metal, including its persistence,
> color
> prepass, 1.8-gamma linearization, reconstruction filters, beam response, light
> spread, and physical-pixel mask. Optional upstream branches are listed under
> Current limitations; exact RetroArch output parity is not claimed yet.

## What makes it a CRT renderer

- **Virtual raster:** HD video is reconstructed as a finite set of CRT scanlines,
  rather than darkened with a repeating overlay.
- **Luminance-dependent beams:** dark details excite narrow beams; highlights
  spread into wider, brighter beams.
- **Physical-pixel phosphor mask:** the final Metal pass maps backing pixels into
  repeating red, green, and blue aperture-grille emitters.
- **Temporal phosphor response:** prior frames feed a persistence pass to model
  phosphors decaying after the beam has moved on.
- **Light transport:** separable glow and bloom passes approximate diffusion,
  while red-biased halation simulates light scattering through the tube.
- **Tube geometry:** curvature, rounded corners, overscan-safe aspect fitting,
  and edge falloff shape the image as a piece of glass.

All intermediate image processing uses private `RGBA16Float` Metal textures.
AVFoundation video frames enter Metal through `CVMetalTextureCache`, avoiding a
CPU-side image conversion or upload for every frame. The graph advances only
when AVFoundation produces a new source frame, so 24/30 fps video does not run
the complete shader chain 60 times per second or decay persistence too quickly.

## Features

- Native SwiftUI/AppKit macOS interface
- AVFoundation playback with a custom `CAMetalLayer` presentation path
- Eleven-stage Metal CRT renderer and one-pass true bypass
- Native-first playback with FFmpeg remux/transcode fallback for Matroska, AVI,
  and uncommon codecs
- NV12 and BGRA video input with Rec. 601/709/2020 matrix handling
- Play/pause, seeking, volume, drag and drop, and full screen
- Live controls for effect strength, curvature, beam scanlines, phosphor mask,
  glow, and vignette
- Retina-aware output and persistent preferences
- Apple Silicon-first, with no web view or cross-platform UI runtime

## Requirements

- Apple Silicon Mac
- macOS 14 or later
- Xcode command-line tools with Swift 6

QuickTime-compatible video works with no extra dependency. For MKV, AVI, and
formats whose container or codec AVFoundation cannot decode, install FFmpeg:

```sh
brew install ffmpeg
```

Phosphor first attempts a lossless, fast container remux. Only when the codec
itself is incompatible does it create a high-quality H.264/AAC playback copy.
It prefers Apple VideoToolbox, falls back to `libx264`, caches the result, and
never changes the original file.

## Build and run

```sh
git clone https://github.com/JoAz111/Phosphor.git
cd Phosphor
./script/build_and_run.sh
```

The script builds the Swift package, stages a proper application bundle at
`dist/Phosphor.app`, copies its Metal source, icon, and GPL notice into the
bundle, then launches it. Normal runs package an optimized release executable;
`--debug` builds the debuggable configuration. The script prefers Xcode Beta
when present because the current SwiftPM resource layout is validated with that
toolchain.

Useful modes:

```sh
./script/build_and_run.sh --verify    # launch and verify the process
./script/build_and_run.sh --debug     # attach LLDB
./script/build_and_run.sh --logs      # stream app logs
./script/build_and_run.sh --telemetry # stream Phosphor subsystem logs
```

Run the tests with:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  swift test --scratch-path "${TMPDIR:-/tmp}/phosphor-swiftpm-tests"
```

The GPU tests compile every shader entry point on a live Metal device and check
Guest's input gamma, empty initial persistence, separated RGB phosphors,
luminance-dependent raster lines, and an unmodified bypass image.

## Controls

- Open video: **Command-O**, drag and drop, or **File > Open Video**
- Play or pause: **Space**
- Seek: timeline
- Full screen: standard macOS full-screen control
- Compare with the source: **Bypass CRT Effect**
- Tune the tube: **Advanced CRT Settings**

## Project structure

```text
Sources/Phosphor/
  App/          Application entry point and identity
  Models/       Rendering and playback value types
  Rendering/    CAMetalLayer integration, frame graph, and color conversion
  Resources/    Metal shaders and application icon
  Stores/       AVFoundation playback state and media loading
  Views/        SwiftUI controls and AppKit/Metal bridge
Tests/          CPU and live-GPU regression tests
script/         Reproducible build, bundle, launch, and debug entry point
```

## Current limitations

- The renderer covers Guest Advanced HD's default progressive path, but not its
  interlacing/VGA branches, optional color LUTs, noise/deconvergence controls,
  or all 15 upstream mask patterns. Its two RetroArch stock-copy passes are
  represented by Phosphor's decoded-current/retained-previous frame buffers
  instead of issuing redundant full-frame GPU copies.
- Phosphor deliberately selects Guest's type 6 RGB aperture-grille mask instead
  of upstream's type 0 default so individual red, green, and blue emitters are
  visible on modern Retina panels.
- Pixel parity against a pinned RetroArch reference capture is still pending.
- Compatibility playback currently uses a locally installed FFmpeg. A future
  signed release can bundle a redistributable FFmpeg build and its notices.
- HDR input currently follows an SDR presentation path and is identified in the
  interface rather than silently advertised as HDR output.
- Development bundles are not Developer ID signed or notarized.

## License and credits

Phosphor is licensed under the
[GNU General Public License, version 2 or any later version](LICENSE).

The renderer contains a modified Metal/macOS adaptation of
[CRT-Guest-Advanced HD](https://github.com/libretro/slang-shaders/tree/master/crt/shaders/guest/hd),
copyright (C) 2018-2025 guest(r), with ideas and contributions from Dr. Venom
and the Libretro shader community. Portions of the mask logic originate in
Timothy Lottes' public-domain CRT shader. See the source headers for attribution
and modification notices. The current translation is based on upstream commit
[`3b0d6aa`](https://github.com/libretro/slang-shaders/commit/3b0d6aa1d134a168478cd9c904a866d969f8882b).

Phosphor invokes FFmpeg as a separate executable when compatibility playback is
needed. FFmpeg is an independent project; see [ffmpeg.org](https://ffmpeg.org/)
for its source code and license information.
