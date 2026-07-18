<p align="center">
  <img src="assets/phosphor-icon.png" width="180" alt="Phosphor app icon">
</p>

<h1 align="center">Phosphor</h1>

<p align="center">
  <strong>Your videos, rebuilt as light.</strong><br>
  A native macOS video player with a real-time, Apple Silicon–optimized CRT renderer.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-111111?logo=apple&logoColor=white" alt="macOS 14 or later">
  <img src="https://img.shields.io/badge/Apple%20Silicon-native-111111" alt="Native Apple Silicon">
  <img src="https://img.shields.io/badge/renderer-Metal-2f855a" alt="Metal renderer">
  <img src="https://img.shields.io/badge/license-GPL--2.0--or--later-2f855a" alt="GPL-2.0-or-later">
</p>

<p align="center">
  <a href="#build-from-source">Build from source</a> ·
  <a href="#how-it-works">How it works</a> ·
  <a href="#fidelity-and-roadmap">Fidelity</a>
</p>

---

Phosphor is not a video player with a scanline texture on top. It reconstructs
each frame as a virtual CRT would: a finite electron-beam raster, brightness-
dependent beam shapes, discrete RGB phosphors, temporal persistence, diffuse
light, and curved glass.

It is native from end to end—SwiftUI and AppKit for the interface, AVFoundation
for playback, and an eleven-stage Metal renderer for the tube.

> [!IMPORTANT]
> Phosphor is an early FOSS preview. The core progressive CRT path is working,
> but exact pixel parity with the complete upstream Guest Advanced preset is not
> claimed yet. See [Fidelity and roadmap](#fidelity-and-roadmap) for the honest
> boundary.

## A CRT, not a filter

- **Individual RGB phosphors.** Choose CRT Guest Advanced's type 6 aperture
  grille or its staggered slot-mask geometry. On Retina displays, both patterns
  scale in physical pixels—not SwiftUI points.
- **Beams that react to the picture.** Dark detail produces narrow scanlines;
  bright areas excite wider, softer beams instead of receiving identical black
  stripes.
- **Light with a memory.** Previous frames feed a phosphor-persistence pass while
  separable glow and bloom stages model light spreading through the tube.
- **Native performance.** Video frames enter Metal through `CVMetalTextureCache`
  and stay in private `RGBA16Float` textures. The graph advances with source
  frames, so 24/30 fps video does not run the full renderer at 60 fps or decay
  persistence too quickly.

## Play almost anything

QuickTime-compatible media opens directly through AVFoundation. For Matroska,
AVI, WebM, and uncommon codecs, Phosphor can fall back to FFmpeg:

1. Try a fast, lossless container remux.
2. If the codec is incompatible, create a high-quality H.264/AAC playback copy.
3. Cache the prepared copy without modifying the original video.

The compatibility path prefers Apple VideoToolbox, then falls back to `libx264`
and a portable MPEG-4 encoder. Install FFmpeg with:

```sh
brew install ffmpeg
```

## Build from source

You will need an Apple Silicon Mac, macOS 14 or later, and the Xcode command-line
tools with Swift 6.

```sh
git clone https://github.com/JoAz111/Phosphor.git
cd Phosphor
./script/build_and_run.sh
```

The script creates an optimized, ad-hoc-signed app at `dist/Phosphor.app` and
launches it. It also installs the app icon, Metal source, file-type declarations,
and GPL notice into the bundle.

Useful development modes:

```sh
./script/build_and_run.sh --verify    # launch and verify the process
./script/build_and_run.sh --debug     # build debug and attach LLDB
./script/build_and_run.sh --logs      # stream app logs
./script/build_and_run.sh --telemetry # stream Phosphor subsystem logs
```

## Using Phosphor

- Open a video with **Command-O**, drag and drop, **File → Open Video**, or
  **Open With → Phosphor** in Finder.
- Play or pause with **Space**.
- Seek and change volume from the floating player controls.
- Use **Bypass CRT Effect** for an immediate source comparison.
- Tune curvature, beam scanlines, phosphor strength, tube glow, and vignette in
  **Advanced CRT Settings**.
- Enter full screen with the standard macOS window control.

## How it works

```text
AVFoundation video
  → zero-copy CVMetalTextureCache input
  → encoded current/previous frame buffers
  → phosphor persistence and color prepass
  → Guest 1.8-gamma linearization
  → horizontal reconstruction
  → glow and bloom diffusion
  → luminance-dependent beam reconstruction
  → physical-pixel RGB aperture grille and glass
  → CAMetalLayer
```

The Metal graph is based on
[CRT-Guest-Advanced HD](https://github.com/libretro/slang-shaders/tree/master/crt/shaders/guest/hd)
and adapted for progressive AVFoundation video, a variable window size, Retina
backing pixels, and Apple Silicon GPUs. A true one-pass bypass remains separate
from the CRT graph.

## Fidelity and roadmap

The current renderer ports Guest Advanced HD's default progressive signal path:
persistence, color prepass, 1.8-gamma linearization, reconstruction filters,
beam response, glow/bloom stages, brightness compensation, and the final mask.

Phosphor includes Guest's type 6 RGB aperture grille and a staggered slot-mask
variant. Both share the same beam, brightness-adaptive phosphor response, and
physical-pixel scaling instead of behaving like unrelated texture presets.

Still to come:

- Pixel-parity fixtures captured from a pinned RetroArch reference renderer
- Optional color LUTs and the remaining Guest shadow-mask patterns
- Interlacing and VGA-specific branches
- Deconvergence and noise controls
- A redistributable bundled FFmpeg build for signed releases
- HDR-native output rather than the current clearly identified SDR path

## Development

Run the complete test suite with:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  swift test --scratch-path "${TMPDIR:-/tmp}/phosphor-swiftpm-tests"
```

The suite includes live-GPU checks for every Metal entry point, Guest's input
gamma, initial persistence, luminance-dependent raster lines, discrete RGB
phosphors, and true bypass. It also exercises a real FFmpeg-to-AVFoundation
Matroska compatibility path.

<details>
<summary>Project structure</summary>

```text
Sources/Phosphor/
  App/          Application entry point and identity
  Models/       Rendering and playback value types
  Rendering/    CAMetalLayer integration, frame graph, and color conversion
  Resources/    Metal shaders and application icon
  Stores/       AVFoundation playback state and media preparation
  Views/        SwiftUI controls and AppKit/Metal bridge
Tests/          CPU and live-GPU regression tests
script/         Build, bundle, launch, and debugging entry point
```

</details>

## License and credits

Phosphor is free software under the
[GNU General Public License, version 2 or any later version](LICENSE).

The renderer is a modified Metal/macOS adaptation of
[CRT-Guest-Advanced HD](https://github.com/libretro/slang-shaders/tree/master/crt/shaders/guest/hd),
copyright © 2018–2025 guest(r), with ideas and contributions from Dr. Venom and
the Libretro shader community. The current translation is based on upstream
commit [`3b0d6aa`](https://github.com/libretro/slang-shaders/commit/3b0d6aa1d134a168478cd9c904a866d969f8882b).
Portions of the mask logic originate in Timothy Lottes' public-domain CRT shader.

Phosphor invokes FFmpeg as an independent executable when compatibility playback
is needed. See [ffmpeg.org](https://ffmpeg.org/) for FFmpeg's source and license
information.
