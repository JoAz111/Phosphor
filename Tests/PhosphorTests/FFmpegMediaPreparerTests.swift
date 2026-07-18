import AVFoundation
import Foundation
import XCTest
@testable import Phosphor

final class FFmpegMediaPreparerTests: XCTestCase {
    func testLocatorPrefersBundledExecutableThenExplicitOverride() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let resources = root.appending(path: "Resources", directoryHint: .isDirectory)
        let bundled = resources.appending(path: "ffmpeg")
        let override = root.appending(path: "custom-ffmpeg")
        try FileManager.default.createDirectory(
            at: resources,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(
            FFmpegExecutableLocator.candidateURLs(
                resourceURL: resources,
                environment: [
                    "PHOSPHOR_FFMPEG_PATH": override.path,
                    "PATH": "/first:/second"
                ]
            ),
            [
                bundled,
                override,
                URL(fileURLWithPath: "/first/ffmpeg"),
                URL(fileURLWithPath: "/second/ffmpeg"),
                URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
                URL(fileURLWithPath: "/usr/local/bin/ffmpeg")
            ]
        )
    }

    func testRemuxArgumentsPreserveStreamsWithoutInvokingAShell() {
        let source = URL(fileURLWithPath: "/tmp/input with spaces.mkv")
        let output = URL(fileURLWithPath: "/tmp/output.mov")

        let arguments = FFmpegMediaPreparer.arguments(
            sourceURL: source,
            outputURL: output,
            mode: .remux
        )

        XCTAssertTrue(arguments.contains(source.path))
        XCTAssertTrue(arguments.contains("0:v:0"))
        XCTAssertTrue(arguments.contains("0:a:0?"))
        XCTAssertEqual(arguments.suffix(3), ["-f", "mov", output.path])
        XCTAssertEqual(Self.value(after: "-c", in: arguments), "copy")
    }

    func testTranscodeArgumentsUseAppleHardwareAndCompatibleAudio() {
        let arguments = FFmpegMediaPreparer.arguments(
            sourceURL: URL(fileURLWithPath: "/tmp/input.avi"),
            outputURL: URL(fileURLWithPath: "/tmp/output.mov"),
            mode: .transcode
        )

        XCTAssertEqual(
            Self.value(after: "-c:v", in: arguments),
            "h264_videotoolbox"
        )
        XCTAssertEqual(Self.value(after: "-c:a", in: arguments), "aac")
        XCTAssertEqual(Self.value(after: "-pix_fmt", in: arguments), "yuv420p")
        XCTAssertEqual(Self.value(after: "-movflags", in: arguments), "+faststart")
    }

    func testTranscodeHasSoftwareAndPortableFallbacks() {
        let source = URL(fileURLWithPath: "/tmp/input.mkv")
        let output = URL(fileURLWithPath: "/tmp/output.mov")
        let x264 = FFmpegMediaPreparer.arguments(
            sourceURL: source,
            outputURL: output,
            mode: .transcode,
            videoEncoder: .libx264
        )
        let portable = FFmpegMediaPreparer.arguments(
            sourceURL: source,
            outputURL: output,
            mode: .transcode,
            videoEncoder: .mpeg4
        )

        XCTAssertEqual(Self.value(after: "-c:v", in: x264), "libx264")
        XCTAssertEqual(Self.value(after: "-crf", in: x264), "16")
        XCTAssertEqual(Self.value(after: "-c:v", in: portable), "mpeg4")
        XCTAssertEqual(Self.value(after: "-q:v", in: portable), "2")
    }

    func testCacheKeyChangesWithPreparationMode() throws {
        let source = FileManager.default.temporaryDirectory
            .appending(path: "phosphor-\(UUID().uuidString).mkv")
        try Data("video".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let remux = try FFmpegMediaPreparer.cacheKey(
            sourceURL: source,
            mode: .remux,
            fileManager: .default
        )
        let transcode = try FFmpegMediaPreparer.cacheKey(
            sourceURL: source,
            mode: .transcode,
            fileManager: .default
        )

        XCTAssertNotEqual(remux, transcode)
        XCTAssertEqual(remux.count, 64)
        XCTAssertEqual(transcode.count, 64)
    }

    func testInstalledFFmpegPreparesMatroskaForAVFoundation() async throws {
        guard let executableURL = FFmpegExecutableLocator.locate() else {
            throw XCTSkip("FFmpeg is not installed")
        }

        let root = FileManager.default.temporaryDirectory
            .appending(path: "phosphor-ffmpeg-\(UUID().uuidString)", directoryHint: .isDirectory)
        let cache = root.appending(path: "cache", directoryHint: .isDirectory)
        let source = root.appending(path: "source.mkv")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Self.run(
            executableURL,
            arguments: [
                "-hide_banner", "-loglevel", "error", "-y",
                "-f", "lavfi",
                "-i", "testsrc2=size=320x180:rate=24",
                "-t", "0.25",
                "-c:v", "ffv1",
                "-an",
                source.path
            ]
        )

        let prepared = try await FFmpegMediaPreparer(
            executableURL: executableURL,
            cacheDirectory: cache
        ).prepare(source, mode: .transcode)
        let asset = AVURLAsset(url: prepared)
        let isPlayable = try await asset.load(.isPlayable)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)

        XCTAssertTrue(isPlayable)
        XCTAssertFalse(videoTracks.isEmpty)
        XCTAssertGreaterThan(
            (try FileManager.default.attributesOfItem(atPath: prepared.path)[.size] as? NSNumber)?
                .int64Value ?? 0,
            0
        )
    }

    private static func value(after option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
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
