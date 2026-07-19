import AVFoundation
import CoreVideo
import QuartzCore

struct VideoFrameUpdate {
    let pixelBuffer: CVPixelBuffer
    let isNew: Bool
}
protocol VideoFrameSource: AnyObject {
    func frame(
        forHostTime hostTime: CFTimeInterval,
        requestedTime: TimeInterval?,
        isPlaying: Bool
    ) -> VideoFrameUpdate?
}

/// Preserves AVPlayerItemVideoOutput's zero-copy Core Video path behind the
/// same source abstraction used by direct FFmpeg decoding.
final class AVFoundationVideoFrameSource: VideoFrameSource {
    let output: AVPlayerItemVideoOutput

    init(output: AVPlayerItemVideoOutput) {
        self.output = output
    }

    func frame(
        forHostTime hostTime: CFTimeInterval,
        requestedTime: TimeInterval?,
        isPlaying: Bool
    ) -> VideoFrameUpdate? {
        let itemTime: CMTime
        if !isPlaying, let requestedTime {
            itemTime = CMTime(seconds: requestedTime, preferredTimescale: 600)
        } else {
            itemTime = output.itemTime(forHostTime: hostTime)
        }
        guard output.hasNewPixelBuffer(forItemTime: itemTime),
              let pixelBuffer = output.copyPixelBuffer(
                  forItemTime: itemTime,
                  itemTimeForDisplay: nil
              ) else {
            return nil
        }
        return VideoFrameUpdate(pixelBuffer: pixelBuffer, isNew: true)
    }
}
