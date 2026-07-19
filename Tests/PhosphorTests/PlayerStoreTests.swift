import AVFoundation
import CoreVideo
import XCTest
@testable import Phosphor

@MainActor
final class PlayerStoreTests: XCTestCase {
    func testPlaybackClockCallbacksNeverAssumeAnExecutor() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot
                .appending(path: "Sources/Phosphor/Stores/PlayerStore.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(
            source.contains("MainActor.assumeIsolated"),
            "Timer and AVPlayer callbacks must hop to MainActor instead of assuming an executor"
        )
    }

    func testEmptyStoreHasDeterministicDefaults() {
        let store = PlayerStore()

        XCTAssertFalse(store.hasMedia)
        XCTAssertEqual(store.transport, .empty)
        XCTAssertEqual(store.currentTime, 0)
        XCTAssertEqual(store.duration, 0)
        XCTAssertEqual(store.nominalFrameRate, 0)
        XCTAssertEqual(store.scanMetadata, .progressive)
        XCTAssertEqual(store.volume, 1)
        XCTAssertNil(store.videoOutput)
        XCTAssertNil(store.frameSource)
        XCTAssertNil(store.currentURL)
        XCTAssertNil(store.errorMessage)
        XCTAssertNil(store.noticeMessage)
        XCTAssertFalse(store.isLoading)
        XCTAssertNil(store.player.currentItem)
    }

    func testVolumeIsClampedAtBothBounds() {
        let store = PlayerStore()

        store.setVolume(-1)
        XCTAssertEqual(store.volume, 0)
        XCTAssertEqual(store.player.volume, 0)

        store.setVolume(2)
        XCTAssertEqual(store.volume, 1)
        XCTAssertEqual(store.player.volume, 1)
    }

    func testTogglingWithoutMediaRemainsEmpty() {
        let store = PlayerStore()

        store.togglePlayback()

        XCTAssertEqual(store.transport, .empty)
        XCTAssertFalse(store.hasMedia)
        XCTAssertEqual(store.player.rate, 0)
    }

    func testInvalidLoadSurfacesConciseErrorWithoutInstallingMedia() async {
        let store = PlayerStore(assetLoader: { _ in
            throw TestLoadError.failed
        })

        await store.load(url: Self.url("invalid")).value

        XCTAssertEqual(store.errorMessage, "The video could not be opened.")
        XCTAssertFalse(store.hasMedia)
        XCTAssertNil(store.currentURL)
        XCTAssertNil(store.videoOutput)
        XCTAssertNil(store.player.currentItem)
        XCTAssertEqual(store.transport, .empty)
    }

    func testFailedLoadPreservesPriorLoadedMediaAndState() async {
        let goodURL = Self.url("good")
        let failedURL = Self.url("failed")
        let prepared = makePreparedPlayerAsset(
            duration: 90,
            metadata: VideoColorMetadata(mediaCharacteristics: [.containsHDRVideo])
        )
        let store = PlayerStore(assetLoader: { url in
            guard url == goodURL else { throw TestLoadError.failed }
            return prepared
        })

        await store.load(url: goodURL).value
        store.togglePlayback()
        store.seek(to: 35)
        let priorItem = store.player.currentItem
        let priorOutput = store.videoOutput

        await store.load(url: failedURL).value

        XCTAssertEqual(store.errorMessage, "The video could not be opened.")
        XCTAssertTrue(store.player.currentItem === priorItem)
        XCTAssertTrue(store.videoOutput === priorOutput)
        XCTAssertEqual(store.currentURL, goodURL)
        XCTAssertEqual(store.transport, .paused)
        XCTAssertEqual(store.currentTime, 35)
        XCTAssertEqual(store.duration, 90)
        XCTAssertEqual(
            store.noticeMessage,
            VideoColorMetadata.hdrSDRPathNotice
        )
    }

    func testOlderSuccessfulLoadCannotReplaceNewerCompletion() async {
        let loader = ControlledPlayerAssetLoader()
        let firstURL = Self.url("first")
        let secondURL = Self.url("second")
        let firstPrepared = makePreparedPlayerAsset(duration: 10)
        let secondPrepared = makePreparedPlayerAsset(
            duration: 20,
            nominalFrameRate: 29.97
        )
        let store = PlayerStore(assetLoader: { url in
            try await loader.load(url: url)
        })

        let firstTask = store.load(url: firstURL)
        await loader.waitUntilRequested(firstURL)
        let secondTask = store.load(url: secondURL)
        await loader.waitUntilRequested(secondURL)
        loader.succeed(secondURL, with: secondPrepared)
        await secondTask.value
        loader.succeed(firstURL, with: firstPrepared)
        await firstTask.value

        XCTAssertEqual(store.currentURL, secondURL)
        XCTAssertTrue(store.player.currentItem === secondPrepared.item)
        XCTAssertTrue(store.videoOutput === secondPrepared.output)
        XCTAssertEqual(store.duration, 20)
        XCTAssertEqual(store.nominalFrameRate, 29.97, accuracy: 0.001)
        XCTAssertNil(store.errorMessage)
    }

    func testLoadedAssetCarriesFieldOrderIntoRendererState() async {
        let metadata = VideoScanMetadata(fieldOrder: .bottomFirst)
        let prepared = makePreparedPlayerAsset(
            duration: 30,
            scanMetadata: metadata
        )
        let store = PlayerStore(assetLoader: { _ in prepared })

        await store.load(url: Self.url("interlaced")).value

        XCTAssertEqual(store.scanMetadata, metadata)
    }

    func testOlderFailedLoadCannotSurfaceStaleError() async {
        let loader = ControlledPlayerAssetLoader()
        let firstURL = Self.url("first-failure")
        let secondURL = Self.url("second-success")
        let secondPrepared = makePreparedPlayerAsset(duration: 20)
        let store = PlayerStore(assetLoader: { url in
            try await loader.load(url: url)
        })

        let firstTask = store.load(url: firstURL)
        await loader.waitUntilRequested(firstURL)
        let secondTask = store.load(url: secondURL)
        await loader.waitUntilRequested(secondURL)
        loader.succeed(secondURL, with: secondPrepared)
        await secondTask.value
        loader.fail(firstURL)
        await firstTask.value

        XCTAssertEqual(store.currentURL, secondURL)
        XCTAssertTrue(store.player.currentItem === secondPrepared.item)
        XCTAssertNil(store.errorMessage)
    }

    func testProductionVideoOutputUsesNV12VideoRangeAndMetalCompatibility() {
        let attributes = AVURLAssetLoader.videoOutputConfiguration.pixelBufferAttributes

        XCTAssertEqual(
            attributes[kCVPixelBufferPixelFormatTypeKey as String] as? OSType,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        XCTAssertEqual(
            attributes[kCVPixelBufferMetalCompatibilityKey as String] as? Bool,
            true
        )
        XCTAssertNotNil(
            attributes[kCVPixelBufferIOSurfacePropertiesKey as String]
        )
        XCTAssertTrue(
            AVURLAssetLoader.videoOutputConfiguration
                .makeVideoOutput()
                .suppressesPlayerRendering
        )
    }

    func testFFmpegDirectNoticeIsPresentedWithHDRNotice() async {
        let prepared = makePreparedPlayerAsset(
            duration: 12,
            metadata: VideoColorMetadata(mediaCharacteristics: [.containsHDRVideo]),
            preparation: .ffmpegDirect
        )
        let store = PlayerStore(assetLoader: { _ in prepared })

        await store.load(url: Self.url("ffmpeg-notice")).value

        XCTAssertEqual(
            store.noticeMessage,
            "\(VideoColorMetadata.hdrSDRPathNotice) Decoding directly with bundled FFmpeg."
        )
        XCTAssertFalse(store.isLoading)
    }

    func testLoadingStateCoversAsynchronousPreparation() async {
        let loader = ControlledPlayerAssetLoader()
        let url = Self.url("loading-state")
        let store = PlayerStore(assetLoader: { url in
            try await loader.load(url: url)
        })

        let task = store.load(url: url)
        await loader.waitUntilRequested(url)
        XCTAssertTrue(store.isLoading)

        loader.succeed(url, with: makePreparedPlayerAsset(duration: 1))
        await task.value
        XCTAssertFalse(store.isLoading)
    }

    func testSeekClampsFiniteValuesToLoadedDuration() async {
        let prepared = makePreparedPlayerAsset(duration: 60)
        let store = PlayerStore(assetLoader: { _ in prepared })
        await store.load(url: Self.url("seek-finite")).value

        store.seek(to: -1)
        XCTAssertEqual(store.currentTime, 0)

        store.seek(to: 25)
        XCTAssertEqual(store.currentTime, 25)

        store.seek(to: 100)
        XCTAssertEqual(store.currentTime, 60)
    }

    func testNonfiniteVolumeUsesDeterministicBounds() {
        let store = PlayerStore()

        store.setVolume(.nan)
        XCTAssertEqual(store.volume, 1)

        store.setVolume(.infinity)
        XCTAssertEqual(store.volume, 1)

        store.setVolume(-.infinity)
        XCTAssertEqual(store.volume, 0)
    }

    func testNonfiniteSeekUsesDeterministicBounds() async {
        let prepared = makePreparedPlayerAsset(duration: 60)
        let store = PlayerStore(assetLoader: { _ in prepared })
        await store.load(url: Self.url("seek-nonfinite")).value

        store.seek(to: .nan)
        XCTAssertEqual(store.currentTime, 0)

        store.seek(to: .infinity)
        XCTAssertEqual(store.currentTime, 60)

        store.seek(to: -.infinity)
        XCTAssertEqual(store.currentTime, 0)
    }

    private static func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/private/tmp/\(name).mov")
    }
}

@MainActor
private final class ControlledPlayerAssetLoader {
    private var continuations: [
        URL: CheckedContinuation<PreparedPlayerAsset, Error>
    ] = [:]

    func load(url: URL) async throws -> PreparedPlayerAsset {
        try await withCheckedThrowingContinuation { continuation in
            continuations[url] = continuation
        }
    }

    func waitUntilRequested(_ url: URL) async {
        while continuations[url] == nil {
            await Task.yield()
        }
    }

    func succeed(_ url: URL, with asset: PreparedPlayerAsset) {
        continuations.removeValue(forKey: url)?.resume(returning: asset)
    }

    func fail(_ url: URL) {
        continuations.removeValue(forKey: url)?.resume(throwing: TestLoadError.failed)
    }
}

@MainActor
private func makePreparedPlayerAsset(
    duration: TimeInterval,
    nominalFrameRate: Float = 0,
    scanMetadata: VideoScanMetadata = .progressive,
    metadata: VideoColorMetadata = VideoColorMetadata(mediaCharacteristics: []),
    preparation: MediaPreparation = .native
) -> PreparedPlayerAsset {
    let item = AVPlayerItem(url: URL(fileURLWithPath: "/dev/null"))
    let output = AVURLAssetLoader.videoOutputConfiguration.makeVideoOutput()
    item.add(output)
    return PreparedPlayerAsset(
        item: item,
        output: output,
        duration: duration,
        nominalFrameRate: nominalFrameRate,
        scanMetadata: scanMetadata,
        colorMetadata: metadata,
        preparation: preparation
    )
}

private enum TestLoadError: Error {
    case failed
}
