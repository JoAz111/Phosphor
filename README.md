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
- **Built to run like butter.** Hardware-decoded frames enter Metal through
  `CVPixelBuffer` surfaces and remain on the GPU through the CRT graph. Phosphor
  reconstructs the tube only when the video produces a new frame.

## Looks heavy. Runs light.

Phosphor is hyper-optimized around the architecture of Apple silicon. Video
frames become Metal textures through `CVMetalTextureCache`; the complete CRT
graph is encoded into one command buffer; intermediate images remain in private
GPU textures; and the final `CAMetalLayer` is framebuffer-only. There is no CPU
readback in the playback path.

Rendering uses two deliberately different clocks. A 24 fps movie gets 24 costly
source-reconstruction updates per second. That work produces a cached,
native-resolution tube-emission texture. A much lighter half-precision temporal
pass follows the Mac display—up to 120 Hz or beyond—to advance channel-specific
phosphor decay without rerunning the full graph for duplicate video frames.
Excitation history uses Apple's compact `RG11B10Float` format where supported,
the wide glow kernel is folded into paired bilinear samples, mask variants are
specialized up front, and in-flight work is deliberately bounded.

Phosphor also measures the final pass with Metal's GPU timestamps. If a display
cadence is genuinely unsustainable, it settles on a stable lower presentation
rate instead of building latency or stuttering, then restores high refresh
after sustained headroom. Occluded windows stop presenting entirely.

That is how Phosphor can simulate a beam, persistence, bloom, glow, individual
RGB phosphors, and curved glass in real time while still feeling like a tiny,
effortless native Mac app—not a GPU benchmark wearing video-player controls.

## Play almost anything

QuickTime-compatible media opens directly through AVFoundation. Matroska, AVI,
WebM, and uncommon codecs fall back to FFmpeg's libraries inside Phosphor. The
decoder reads the original file directly into a bounded in-memory frame queue,
prefers VideoToolbox hardware decoding, and sends audio straight to
`AVAudioEngine`.

**Phosphor never invokes the `ffmpeg` command, remuxes the video, converts it,
or creates a prepared playback copy.** The original file is the only media file
it reads.

## Build from source

You will need an Apple Silicon Mac, macOS 14 or later, Xcode with the Metal
toolchain, and FFmpeg's development libraries for a quick local build.

```sh
git clone https://github.com/JoAz111/Phosphor.git
cd Phosphor
brew install ffmpeg
./script/build_and_run.sh
```

The script creates an optimized, ad-hoc-signed app at `dist/Phosphor.app` and
launches it. The app icon, compiled Metal library, compatible FFmpeg libraries,
file declarations, and license notices live inside that `.app`; the resulting
bundle does not need Homebrew on the destination Mac.

### Build a signed GitHub release

The release builder downloads and checksum-verifies pinned FFmpeg 8.1.2 source,
builds only its local playback libraries for arm64/macOS 14, links them
statically into Phosphor, enables the hardened runtime, and produces
`dist/Phosphor.zip`:

```sh
./script/build_release.sh "Developer ID Application: Your Name (TEAMID)"
```

To submit, staple, and repackage it in the same pass, first save notarytool
credentials in a Keychain profile and provide that profile name:

```sh
./script/build_release.sh \
  "Developer ID Application: Your Name (TEAMID)" \
  "phosphor-notary"
```

The release build contains no FFmpeg executable and no non-system dynamic
library dependency. Upload `dist/Phosphor.zip` to GitHub Releases.

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
AVFoundation or in-process FFmpeg decode
  → VideoToolbox CVPixelBuffer / Metal-compatible software fallback
  → CVMetalTextureCache input
  → RGB / S-Video / NTSC / PAL signal reconstruction
  → encoded current/previous frame buffers
  → source history and color prepass
  → Guest 1.8-gamma linearization
  → horizontal reconstruction
  → folded glow and bloom diffusion
  → cached native-resolution tube emission with optional alternating fields
  → display-rate, channel-specific RGB phosphor excitation and decay
  → physical-pixel aperture grille or 2D slot lattice, halation, and glass
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
slot lattice and black matrix, adaptive GPU budgeting, and true bypass. It also
decodes a real Matroska file through the in-process FFmpeg path and verifies
that playback creates no prepared media.

<details>
<summary>Project structure</summary>

```text
Sources/Phosphor/
  App/          Application entry point and identity
  Models/       Rendering and playback value types
  Rendering/    CAMetalLayer integration, frame graph, and color conversion
  Resources/    Metal shaders and application icon
  Stores/       AVFoundation and direct FFmpeg playback state
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

Phosphor links FFmpeg's `libavformat`, `libavcodec`, `libavutil`, `libswscale`,
and `libswresample` libraries for compatibility playback. Release builds pin
FFmpeg 8.1.2 and reproduce the exact library configuration in
`script/build_ffmpeg.sh`; see [ffmpeg.org](https://ffmpeg.org/) for its source
and LGPL license information. FFmpeg remains a separate third-party project and
is not endorsed by or affiliated with Phosphor.
