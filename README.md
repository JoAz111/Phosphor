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
> Phosphor is an early preview. The current renderer is a native Metal adaptation
> of Guest Advanced's central beam, mask, persistence, glow, bloom, and halation
> techniques. It is not yet a pass-for-pass reproduction of the complete upstream
> preset. Exact output parity is active work and will be measured against pinned
> upstream reference renders.

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
CPU-side image conversion or upload for every frame.

## Features

- Native SwiftUI/AppKit macOS interface
- AVFoundation playback with a custom `CAMetalLayer` presentation path
- Nine-pass Metal CRT renderer and one-pass true bypass
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

## Build and run

```sh
git clone https://github.com/JoAz111/Phosphor.git
cd Phosphor
./script/build_and_run.sh
```

The script builds the Swift package, stages a proper application bundle at
`dist/Phosphor.app`, copies its Metal source, icon, and GPL notice into the
bundle, then launches it. It prefers Xcode Beta when present because the current
SwiftPM resource layout is validated with that toolchain.

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
that the renderer produces separated RGB phosphors, luminance-dependent raster
lines, and an unmodified bypass image.

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

- The published renderer is a reduced Guest Advanced adaptation, not yet the
  complete 12-pass upstream graph.
- Playback currently depends on AVFoundation's native container and codec
  support. FFmpeg-backed MKV/AVI and uncommon-codec fallback is in development.
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
and modification notices.
