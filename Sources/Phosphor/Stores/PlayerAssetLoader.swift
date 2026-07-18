import AVFoundation
import CoreVideo

typealias PlayerAssetLoading =
    @MainActor @Sendable (URL) async throws -> PreparedPlayerAsset

struct PreparedPlayerAsset: Sendable {
    let item: AVPlayerItem
    let output: AVPlayerItemVideoOutput
    let duration: TimeInterval
    let colorMetadata: VideoColorMetadata
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
            kCVPixelBufferMetalCompatibilityKey as String: isMetalCompatible
        ]
    }

    func makeVideoOutput() -> AVPlayerItemVideoOutput {
        AVPlayerItemVideoOutput(pixelBufferAttributes: pixelBufferAttributes)
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

        let output = videoOutputConfiguration.makeVideoOutput()
        let item = AVPlayerItem(asset: asset)
        item.add(output)

        return PreparedPlayerAsset(
            item: item,
            output: output,
            duration: loadedDuration.seconds,
            colorMetadata: VideoColorMetadata(
                mediaCharacteristics: characteristics
            )
        )
    }
}

enum PlayerLoadError: Error {
    case notPlayable
    case noVideoTrack
}
