import CPhosphorFFmpeg
import CoreVideo
import XCTest
@testable import Phosphor

@MainActor
final class FFmpegDirectPlaybackTests: XCTestCase {
    func testDirectDecoderReadsMatroskaWithoutCreatingPreparedMedia() throws {
        let executable = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw XCTSkip("FFmpeg development runtime is not installed")
        }

        let root = FileManager.default.temporaryDirectory
            .appending(path: "phosphor-direct-\(UUID().uuidString)", directoryHint: .isDirectory)
        let source = root.appending(path: "source.mkv")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Self.run(executable, arguments: [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi",
            "-i", "testsrc2=size=320x180:rate=24",
            "-t", "0.35",
            "-c:v", "ffv1",
            "-an",
            source.path
        ])
        let filesBefore = try Set(FileManager.default.contentsOfDirectory(atPath: root.path))

        let session = try FFmpegPlaybackSession(url: source)
        var update: VideoFrameUpdate?
        for _ in 0 ..< 100 where update == nil {
            update = session.frameSource.frame(
                forHostTime: ProcessInfo.processInfo.systemUptime,
                requestedTime: 0,
                isPlaying: false
            )
            if update == nil {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }

        let frame = try XCTUnwrap(update?.pixelBuffer)
        XCTAssertEqual(CVPixelBufferGetWidth(frame), 320)
        XCTAssertEqual(CVPixelBufferGetHeight(frame), 180)
        XCTAssertEqual(session.nominalFrameRate, 24, accuracy: 0.01)
        XCTAssertGreaterThan(session.duration, 0)
        XCTAssertEqual(
            try Set(FileManager.default.contentsOfDirectory(atPath: root.path)),
            filesBefore,
            "Direct playback must not remux, transcode, or create a cache file"
        )
    }

    func testDirectDecoderRejectsMissingInput() {
        XCTAssertThrowsError(
            try FFmpegPlaybackSession(
                url: URL(fileURLWithPath: "/private/tmp/phosphor-missing-\(UUID().uuidString).mkv")
            )
        )
    }

    func testDirectAudioDecoderProducesPCMWithoutCreatingPreparedMedia() throws {
        let executable = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw XCTSkip("FFmpeg development runtime is not installed")
        }

        let root = FileManager.default.temporaryDirectory
            .appending(path: "phosphor-audio-\(UUID().uuidString)", directoryHint: .isDirectory)
        let source = root.appending(path: "source.mkv")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Self.run(executable, arguments: [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=24",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
            "-t", "0.35", "-shortest",
            "-c:v", "ffv1", "-c:a", "pcm_s16le",
            source.path
        ])
        let filesBefore = try Set(FileManager.default.contentsOfDirectory(atPath: root.path))

        var errorBytes = [CChar](repeating: 0, count: 512)
        let decoder = source.withUnsafeFileSystemRepresentation { path in
            phosphor_ffmpeg_audio_open(path, &errorBytes, errorBytes.count)
        }
        let unwrappedDecoder = try XCTUnwrap(decoder)
        defer { phosphor_ffmpeg_audio_close(unwrappedDecoder) }

        var samples = [Float](repeating: 0, count: 4_096 * 2)
        var presentationTime = 0.0
        let decodedFrames = samples.withUnsafeMutableBufferPointer {
            phosphor_ffmpeg_audio_read(
                unwrappedDecoder,
                $0.baseAddress,
                4_096,
                &presentationTime
            )
        }

        XCTAssertGreaterThan(decodedFrames, 0)
        XCTAssertGreaterThan(
            samples.prefix(Int(decodedFrames) * 2).reduce(0) { $0 + abs($1) },
            0.1
        )
        XCTAssertGreaterThanOrEqual(presentationTime, 0)
        XCTAssertEqual(
            try Set(FileManager.default.contentsOfDirectory(atPath: root.path)),
            filesBefore,
            "Direct audio playback must not create a converted media file"
        )
    }

    func testPlayerStoreRunsDirectMatroskaClockWithoutExecutorHops() async throws {
        let executable = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw XCTSkip("FFmpeg development runtime is not installed")
        }

        let root = FileManager.default.temporaryDirectory
            .appending(path: "phosphor-store-\(UUID().uuidString)", directoryHint: .isDirectory)
        let source = root.appending(path: "source.mkv")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Self.run(executable, arguments: [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=24",
            "-t", "1.0", "-c:v", "ffv1", "-an",
            source.path
        ])
        let filesBefore = try Set(FileManager.default.contentsOfDirectory(atPath: root.path))
        let session = try FFmpegPlaybackSession(url: source)
        let prepared = PreparedPlayerAsset(ffmpegSession: session)
        let store = PlayerStore(assetLoader: { _ in prepared })

        await store.load(url: source).value
        try await Task.sleep(for: .milliseconds(350))

        XCTAssertEqual(store.transport, .playing)
        XCTAssertGreaterThan(store.currentTime, 0.15)
        XCTAssertEqual(
            try Set(FileManager.default.contentsOfDirectory(atPath: root.path)),
            filesBefore,
            "Integrated FFmpeg playback must not create prepared media"
        )
        store.togglePlayback()
    }

    private static func run(_ executableURL: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
