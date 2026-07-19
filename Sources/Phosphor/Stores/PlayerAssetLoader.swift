import AVFoundation
import CoreVideo

typealias PlayerAssetLoading =
    @MainActor @Sendable (URL) async throws -> PreparedPlayerAsset

struct PreparedPlayerAsset: Sendable {
    let item: AVPlayerItem
    let output: AVPlayerItemVideoOutput
    let duration: TimeInterval
    let nominalFrameRate: Float
    let scanMetadata: VideoScanMetadata
    let colorMetadata: VideoColorMetadata
    let preparation: MediaPreparation

    init(
        item: AVPlayerItem,
        output: AVPlayerItemVideoOutput,
        duration: TimeInterval,
        nominalFrameRate: Float = 0,
        scanMetadata: VideoScanMetadata = .progressive,
        colorMetadata: VideoColorMetadata,
        preparation: MediaPreparation
    ) {
        self.item = item
        self.output = output
        self.duration = duration
        self.nominalFrameRate = nominalFrameRate
        self.scanMetadata = scanMetadata
        self.colorMetadata = colorMetadata
        self.preparation = preparation
    }

    func prepared(using preparation: MediaPreparation) -> PreparedPlayerAsset {
        PreparedPlayerAsset(
            item: item,
            output: output,
            duration: duration,
            nominalFrameRate: nominalFrameRate,
            scanMetadata: scanMetadata,
            colorMetadata: colorMetadata,
            preparation: preparation
        )
    }
}

enum MediaPreparation: Sendable, Equatable {
    case native
    case ffmpegRemux
    case ffmpegTranscode

    var notice: String? {
        switch self {
        case .native:
            nil
        case .ffmpegRemux:
            "Opened through FFmpeg compatibility mode."
        case .ffmpegTranscode:
            "Prepared a compatible playback copy with FFmpeg."
        }
    }
}

struct VideoOutputConfiguration: Equatable, Sendable {
    static let player = VideoOutputConfiguration(
        pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        isMetalCompatible: true
    )

    let pixelFormat: OSType
    let isMetalCompatible: Bool

    var pixelBufferAttributes: [String: any Sendable] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferMetalCompatibilityKey as String: isMetalCompatible,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: String]()
        ]
    }

    func makeVideoOutput() -> AVPlayerItemVideoOutput {
        let output = AVPlayerItemVideoOutput(
            pixelBufferAttributes: pixelBufferAttributes
        )
        output.suppressesPlayerRendering = true
        return output
    }
}

enum AVURLAssetLoader {
    static let videoOutputConfiguration = VideoOutputConfiguration.player

    @MainActor
    static func load(url: URL) async throws -> PreparedPlayerAsset {
        let asset = AVURLAsset(url: url)
        async let isPlayable = asset.load(.isPlayable)
        async let assetDuration = asset.load(.duration)
        async let videoTracks = asset.loadTracks(withMediaType: .video)

        let (playable, loadedDuration, tracks) = try await (
            isPlayable,
            assetDuration,
            videoTracks
        )
        guard playable else {
            throw PlayerLoadError.notPlayable
        }
        guard !tracks.isEmpty else {
            throw PlayerLoadError.noVideoTrack
        }

        var characteristics = Set<AVMediaCharacteristic>()
        for track in tracks {
            characteristics.formUnion(try await track.load(.mediaCharacteristics))
        }
        let nominalFrameRate = (try? await tracks[0].load(.nominalFrameRate)) ?? 0
        let formatDescriptions = (
            try? await tracks[0].load(.formatDescriptions)
        ) ?? []

        let output = videoOutputConfiguration.makeVideoOutput()
        let item = AVPlayerItem(asset: asset)
        item.add(output)

        return PreparedPlayerAsset(
            item: item,
            output: output,
            duration: loadedDuration.seconds,
            nominalFrameRate: nominalFrameRate,
            scanMetadata: VideoScanMetadata(
                formatDescriptions: formatDescriptions
            ),
            colorMetadata: VideoColorMetadata(
                mediaCharacteristics: characteristics
            ),
            preparation: .native
        )
    }
}

enum AdaptivePlayerAssetLoader {
    @MainActor
    static func load(url: URL) async throws -> PreparedPlayerAsset {
        do {
            return try await AVURLAssetLoader.load(url: url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return try await loadUsingFFmpeg(url: url)
        }
    }

    @MainActor
    private static func loadUsingFFmpeg(url: URL) async throws -> PreparedPlayerAsset {
        guard let executableURL = FFmpegExecutableLocator.locate() else {
            throw PlayerLoadError.ffmpegUnavailable
        }

        let preparer = FFmpegMediaPreparer(executableURL: executableURL)

        do {
            let remuxedURL = try await preparer.prepare(url, mode: .remux)
            return try await AVURLAssetLoader.load(url: remuxedURL)
                .prepared(using: .ffmpegRemux)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Some Matroska and AVI files contain codecs that QuickTime cannot
            // decode even after their container is replaced. Convert those to
            // a predictable VideoToolbox H.264 and AAC compatibility copy.
        }

        do {
            let transcodedURL = try await preparer.prepare(url, mode: .transcode)
            return try await AVURLAssetLoader.load(url: transcodedURL)
                .prepared(using: .ffmpegTranscode)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PlayerLoadError.ffmpegFailed
        }
    }
}

enum PlayerLoadError: Error {
    case notPlayable
    case noVideoTrack
    case ffmpegUnavailable
    case ffmpegFailed
}
