import AVFoundation
import CoreVideo

typealias PlayerAssetLoading =
    @MainActor @Sendable (URL) async throws -> PreparedPlayerAsset

struct PreparedPlayerAsset: @unchecked Sendable {
    let item: AVPlayerItem?
    let output: AVPlayerItemVideoOutput?
    let frameSource: any VideoFrameSource
    let ffmpegSession: FFmpegPlaybackSession?
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
        frameSource = AVFoundationVideoFrameSource(output: output)
        ffmpegSession = nil
        self.duration = duration
        self.nominalFrameRate = nominalFrameRate
        self.scanMetadata = scanMetadata
        self.colorMetadata = colorMetadata
        self.preparation = preparation
    }

    @MainActor
    init(ffmpegSession: FFmpegPlaybackSession) {
        item = nil
        output = nil
        frameSource = ffmpegSession.frameSource
        self.ffmpegSession = ffmpegSession
        duration = ffmpegSession.duration
        nominalFrameRate = ffmpegSession.nominalFrameRate
        scanMetadata = ffmpegSession.scanMetadata
        colorMetadata = ffmpegSession.colorMetadata
        preparation = .ffmpegDirect
    }

    func prepared(using preparation: MediaPreparation) -> PreparedPlayerAsset {
        guard let item, let output else { return self }
        return PreparedPlayerAsset(
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
    case ffmpegDirect

    var notice: String? {
        switch self {
        case .native:
            nil
        case .ffmpegDirect:
            "Decoding directly with bundled FFmpeg."
        }
    }
}

struct VideoOutputConfiguration: Equatable, Sendable {
    static let player = VideoOutputConfiguration(
        pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        isMetalCompatible: true,
        allowsWideColor: false,
        colorProperties: nil
    )
    static let hdr = VideoOutputConfiguration(
        pixelFormat: kCVPixelFormatType_64RGBAHalf,
        isMetalCompatible: true,
        allowsWideColor: true,
        colorProperties: [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_Linear,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
        ]
    )

    let pixelFormat: OSType
    let isMetalCompatible: Bool
    let allowsWideColor: Bool
    let colorProperties: [String: String]?

    var pixelBufferAttributes: [String: any Sendable] {
        var attributes: [String: any Sendable] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferMetalCompatibilityKey as String: isMetalCompatible,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: String]()
        ]
        if allowsWideColor {
            attributes[AVVideoAllowWideColorKey] = true
        }
        if let colorProperties {
            attributes[AVVideoColorPropertiesKey] = colorProperties
        }
        return attributes
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

        let containsHDR = characteristics.contains(.containsHDRVideo)
        let output = (containsHDR
            ? VideoOutputConfiguration.hdr
            : videoOutputConfiguration
        ).makeVideoOutput()
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
        do {
            return try PreparedPlayerAsset(
                ffmpegSession: FFmpegPlaybackSession(url: url)
            )
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
    case ffmpegFailed
}
