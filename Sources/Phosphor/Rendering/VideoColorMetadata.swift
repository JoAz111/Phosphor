import AVFoundation

struct VideoColorMetadata: Equatable, Sendable {
    static let hdrSDRPathNotice = "HDR video is rendered through the SDR path."

    let containsHDRVideo: Bool

    init(mediaCharacteristics: Set<AVMediaCharacteristic>) {
        containsHDRVideo = mediaCharacteristics.contains(.containsHDRVideo)
    }

    var sdrPathNotice: String? {
        containsHDRVideo ? Self.hdrSDRPathNotice : nil
    }
}
