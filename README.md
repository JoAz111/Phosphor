# Phosphor

Phosphor is a first-pass, open-source macOS video player for presenting local
video through a real-time CRT simulation. The current scaffold establishes the
native SwiftUI package, product identity, and packaged Metal shader boundary;
video playback and CRT rendering are not yet verified.

## Requirements

- Apple Silicon Mac
- macOS 14 or later
- Xcode beta command-line tools

## Build

The intended app build-and-run command is:

```sh
./script/build_and_run.sh
```

That staging script is not part of this initial package scaffold. Until it is
added, validate the package with:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test
```

## License and shader credit

Phosphor is released under the [MIT License](LICENSE). Its future CRT shader is
informed by Timothy Lottes' public-domain CRT shader; Phosphor's Metal
implementation is maintained as native project code.
