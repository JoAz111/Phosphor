import AVFoundation

struct VideoColorMetadata: Equatable, Sendable {
    static let hdrPlaybackNotice = "HDR source is color-managed through the CRT tube model."

    let containsHDRVideo: Bool

    init(containsHDRVideo: Bool) {
        self.containsHDRVideo = containsHDRVideo
    }

    init(mediaCharacteristics: Set<AVMediaCharacteristic>) {
        containsHDRVideo = mediaCharacteristics.contains(.containsHDRVideo)
    }

    var playbackNotice: String? {
        containsHDRVideo ? Self.hdrPlaybackNotice : nil
    }
}
