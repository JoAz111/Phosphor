<p align="center">
  <img src="assets/phosphor-icon.png" width="180" alt="Phosphor app icon">
</p>

<h1 align="center">Phosphor</h1>

<p align="center">
  <strong>A CRT television, living inside your Mac.</strong><br>
  Real phosphors, electron-beam behavior, glow, persistence, and curved glass—<br>
  rebuilt in native Metal and hyper-optimized for Apple silicon.
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

Drop in a video and Phosphor turns your Mac into a beautifully imperfect CRT.
It does not place a scanline texture over the picture. It reconstructs every
frame as a virtual tube would: a finite electron-beam raster, brightness-
dependent beam shapes, discrete RGB phosphors, temporal persistence, diffuse
light, and curved glass.

It is native from end to end—SwiftUI and AppKit for the interface, AVFoundation
for playback, and a multi-pass Metal renderer for the tube. The result looks
computationally extravagant, but runs like butter without making Apple silicon
break a sweat.

> [!IMPORTANT]
> Phosphor is an early FOSS preview. The physical CRT path is working,
> but exact pixel parity with the complete upstream Guest Advanced preset is not
> claimed yet. See [Fidelity and roadmap](#fidelity-and-roadmap) for the honest
> boundary.

## A CRT, not a filter

- **Individual RGB phosphors.** Choose a continuous aperture grille or a true
  two-dimensional slot-mask lattice. Slot mode draws separate rounded R/G/B
  deposits, a black matrix in both axes, and vertically staggered neighboring
  triads. On Retina displays, both patterns use physical pixels—not SwiftUI
  points.
- **Beams that react to the picture.** Dark detail produces narrow scanlines;
  bright areas excite wider, softer beams instead of receiving identical black
  stripes.
- **A raster with time.** 240p is progressive; 480i alternates fields. At high
  display refresh rates the virtual beam advances through part of the raster on
  every presentation instead of stamping the whole image at once.
- **Light with a memory.** A native-resolution excitation buffer gives red,
  green, and blue phosphors separate decay curves while glow, bloom, and warm
  faceplate scatter spread light through the tube.
- **Analog inputs.** Select clean RGB, bandwidth-limited S-Video, NTSC composite,
  or PAL composite with chroma delay, dot crawl, and cross-color behavior.
- **Built to run like butter.** Video frames enter Metal without a CPU-side
  image copy and remain on the GPU through the entire CRT graph. Phosphor only
  performs the expensive work when the video actually produces a new frame.

## Looks heavy. Runs light.

Phosphor is hyper-optimized around the architecture of Apple silicon. Video
frames become Metal textures through `CVMetalTextureCache`; the complete CRT
graph is encoded into one command buffer; intermediate images remain in private
`RGBA16Float` GPU textures; and the final `CAMetalLayer` is framebuffer-only.
There is no CPU readback in the playback path.

Rendering uses two deliberately different clocks. A 24 fps movie gets 24 costly
source-reconstruction updates per second. A much lighter final pass follows the
Mac display—up to 120 Hz or beyond—to advance the beam and phosphor state. That
is what preserves temporal CRT behavior without rerunning the full graph for
duplicate video frames. Pipeline states are created up front, mask variants are
specialized with Metal function constants, occluded windows stop presenting,
and in-flight work is deliberately bounded to keep playback responsive.

That is how Phosphor can simulate a beam, persistence, bloom, glow, individual
RGB phosphors, and curved glass in real time while still feeling like a tiny,
effortless native Mac app—not a GPU benchmark wearing video-player controls.

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
- Choose a Consumer TV, Trinitron, or PVM tube calibration in **Advanced CRT
  Settings**, then tune raster mode, analog signal, persistence, convergence,
  focus, curvature, scanlines, mask, glow, and vignette.
- Enter full screen with the standard macOS window control.

## How it works

```text
AVFoundation video
  → zero-copy CVMetalTextureCache input
  → RGB / S-Video / NTSC / PAL signal reconstruction
  → encoded current/previous frame buffers
  → source history and color prepass
  → Guest 1.8-gamma linearization
  → horizontal reconstruction
  → glow and bloom diffusion
  → display-rate beam and optional alternating fields
  → native-resolution RGB phosphor excitation and decay
  → physical-pixel aperture grille or 2D slot lattice and glass
  → CAMetalLayer
```

The Metal graph is based on
[CRT-Guest-Advanced HD](https://github.com/libretro/slang-shaders/tree/master/crt/shaders/guest/hd)
and adapted for AVFoundation video, interlaced field metadata, a variable window
size, Retina backing pixels, and Apple Silicon GPUs. A true one-pass bypass
remains separate from the CRT graph.

## Fidelity and roadmap

The current renderer ports Guest Advanced HD's core signal path: source history,
color prepass, 1.8-gamma linearization, reconstruction filters, luminance-driven
beam response, glow/bloom stages, brightness compensation, and the final mask.
Phosphor adds a display-rate electron-beam model, automatic field metadata plus
explicit 240p/480i modes, native-resolution channel-specific phosphor decay,
analog signal choices, tube profiles, edge focus, and convergence error.

Phosphor includes Guest's type 6 RGB aperture grille and a separately modeled
shadow-mask lattice. The slot mask is not grille output with horizontal bars:
each RGB deposit has its own rounded aperture and surrounding black matrix, and
alternating triads are offset vertically. Bright emitters grow into the matrix
the way an energized beam spot grows on a tube.

Still to come:

- Pixel-parity fixtures captured from a pinned RetroArch reference renderer
- Optional color LUTs and the remaining Guest shadow-mask patterns
- Additional shadow-mask geometries and VGA-specific branches
- Calibrated RF input, vertical sync instability, and service-menu controls
- A redistributable bundled FFmpeg build for signed releases
- HDR-native output rather than the current clearly identified SDR path

## Development

Run the complete test suite with:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  swift test --scratch-path "${TMPDIR:-/tmp}/phosphor-swiftpm-tests"
```

The suite includes live-GPU checks for every Metal entry point, Guest's input
gamma, channel-specific phosphor decay, alternating interlaced fields,
luminance-dependent raster lines, discrete RGB phosphors, the two-dimensional
slot lattice and black matrix, and true bypass. It also exercises a real
FFmpeg-to-AVFoundation Matroska compatibility path.

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
