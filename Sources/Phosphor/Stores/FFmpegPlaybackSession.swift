import AVFoundation
import CPhosphorFFmpeg
import CoreVideo
import Foundation

enum FFmpegPlaybackError: Error, Equatable {
    case unavailable(String)
    case decodeFailed
}

final class FFmpegPlaybackClock: @unchecked Sendable {
    private let lock = NSLock()
    private var anchorMediaTime: TimeInterval = 0
    private var anchorHostTime = ProcessInfo.processInfo.systemUptime
    private var playing = false

    func currentTime(at hostTime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval {
        lock.withLock {
            playing ? anchorMediaTime + max(hostTime - anchorHostTime, 0) : anchorMediaTime
        }
    }

    func play() {
        lock.withLock {
            guard !playing else { return }
            anchorHostTime = ProcessInfo.processInfo.systemUptime
            playing = true
        }
    }

    func pause() {
        lock.withLock {
            guard playing else { return }
            let now = ProcessInfo.processInfo.systemUptime
            anchorMediaTime += max(now - anchorHostTime, 0)
            anchorHostTime = now
            playing = false
        }
    }

    func seek(to time: TimeInterval) {
        lock.withLock {
            anchorMediaTime = time.isFinite ? max(time, 0) : 0
            anchorHostTime = ProcessInfo.processInfo.systemUptime
        }
    }
}

final class FFmpegVideoFrameSource: VideoFrameSource, @unchecked Sendable {
    private struct BufferedFrame {
        let pixelBuffer: CVPixelBuffer
        let presentationTime: TimeInterval
        let sequence: UInt64
    }

    private let condition = NSCondition()
    private let decodeQueue = DispatchQueue(
        label: "com.joeyazizoff.Phosphor.FFmpegVideo",
        qos: .userInitiated
    )
    private let clock: FFmpegPlaybackClock
    private var decoder: OpaquePointer?
    private var frames: [BufferedFrame] = []
    private var lastFrame: BufferedFrame?
    private var nextSequence: UInt64 = 0
    private var deliveredSequence: UInt64?
    private var pendingSeek: TimeInterval?
    private var isClosed = false
    private var reachedEnd = false

    init(decoder: OpaquePointer, clock: FFmpegPlaybackClock) {
        self.decoder = decoder
        self.clock = clock
        decodeQueue.async { [self] in decodeLoop() }
    }

    deinit {
        shutdown()
    }

    func shutdown() {
        condition.withLock {
            isClosed = true
            condition.broadcast()
        }
    }

    func seek(to time: TimeInterval) {
        condition.withLock {
            pendingSeek = max(time, 0)
            frames.removeAll(keepingCapacity: true)
            lastFrame = nil
            deliveredSequence = nil
            reachedEnd = false
            condition.broadcast()
        }
    }

    func frame(
        forHostTime hostTime: CFTimeInterval,
        requestedTime: TimeInterval?,
        isPlaying: Bool
    ) -> VideoFrameUpdate? {
        let desiredTime = requestedTime ?? clock.currentTime(at: hostTime)
        return condition.withLock {
            while let first = frames.first,
                  first.presentationTime <= desiredTime + 0.002 {
                lastFrame = frames.removeFirst()
                condition.signal()
            }
            if lastFrame == nil,
               let first = frames.first,
               desiredTime <= first.presentationTime + 0.050 {
                lastFrame = frames.removeFirst()
                condition.signal()
            }
            guard let lastFrame else { return nil }
            let isNew = deliveredSequence != lastFrame.sequence
            deliveredSequence = lastFrame.sequence
            return VideoFrameUpdate(
                pixelBuffer: lastFrame.pixelBuffer,
                isNew: isNew
            )
        }
    }

    private func decodeLoop() {
        while true {
            let work: (decoder: OpaquePointer, seek: TimeInterval?)? = condition.withLock {
                while !isClosed,
                      pendingSeek == nil,
                      (frames.count >= 10 || reachedEnd) {
                    condition.wait()
                }
                guard !isClosed, let decoder else { return nil }
                let seek = pendingSeek
                pendingSeek = nil
                return (decoder, seek)
            }
            guard let work else { break }

            if let seek = work.seek {
                _ = phosphor_ffmpeg_video_seek(work.decoder, seek)
            }

            var unmanagedPixelBuffer: Unmanaged<CVPixelBuffer>?
            var presentationTime = 0.0
            let status = phosphor_ffmpeg_video_read(
                work.decoder,
                &unmanagedPixelBuffer,
                &presentationTime
            )
            let pixelBuffer = unmanagedPixelBuffer?.takeRetainedValue()
            condition.withLock {
                if status == 1, let pixelBuffer {
                    nextSequence &+= 1
                    frames.append(BufferedFrame(
                        pixelBuffer: pixelBuffer,
                        presentationTime: max(presentationTime, 0),
                        sequence: nextSequence
                    ))
                } else if status == 0 {
                    reachedEnd = true
                } else if status < 0 {
                    reachedEnd = true
                }
                condition.broadcast()
            }
        }
        if let decoder {
            phosphor_ffmpeg_video_close(decoder)
            self.decoder = nil
        }
    }
}

final class FFmpegAudioOutput: @unchecked Sendable {
    static let playbackFormat = AVAudioFormat(
        standardFormatWithSampleRate: 48_000,
        channels: 2
    )!

    private let condition = NSCondition()
    private let decodeQueue = DispatchQueue(
        label: "com.joeyazizoff.Phosphor.FFmpegAudio",
        qos: .userInitiated
    )
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let format = playbackFormat
    private var decoder: OpaquePointer?
    private var playing = false
    private var isClosed = false
    private var queuedBuffers = 0
    private var generation: UInt64 = 0
    private var pendingSeek: TimeInterval?

    init?(decoder: OpaquePointer?) {
        guard let decoder else { return nil }
        self.decoder = decoder
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            phosphor_ffmpeg_audio_close(decoder)
            self.decoder = nil
            return nil
        }
        decodeQueue.async { [self] in decodeLoop() }
    }

    deinit {
        shutdown()
    }

    func shutdown() {
        condition.withLock {
            isClosed = true
            condition.broadcast()
        }
        playerNode.stop()
        engine.stop()
    }

    var volume: Float {
        get { playerNode.volume }
        set { playerNode.volume = min(max(newValue, 0), 1) }
    }

    func play() {
        condition.withLock {
            playing = true
            condition.broadcast()
        }
        playerNode.play()
    }

    func pause() {
        condition.withLock { playing = false }
        playerNode.pause()
    }

    func seek(to time: TimeInterval, resume: Bool) {
        playerNode.stop()
        condition.withLock {
            generation &+= 1
            queuedBuffers = 0
            pendingSeek = max(time, 0)
            playing = resume
            condition.broadcast()
        }
        if resume {
            playerNode.play()
        }
    }

    private func decodeLoop() {
        let maximumFrames = 4_096
        var samples = [Float](repeating: 0, count: maximumFrames * 2)

        while true {
            let work: (decoder: OpaquePointer, seek: TimeInterval?, generation: UInt64)? = condition.withLock {
                while !isClosed,
                      !playing,
                      pendingSeek == nil {
                    condition.wait()
                }
                while !isClosed,
                      pendingSeek == nil,
                      queuedBuffers >= 6 {
                    condition.wait()
                }
                guard !isClosed, let decoder else { return nil }
                let seek = pendingSeek
                pendingSeek = nil
                return (decoder, seek, generation)
            }
            guard let work else { break }
            if let seek = work.seek {
                _ = phosphor_ffmpeg_audio_seek(work.decoder, seek)
            }

            var presentationTime = 0.0
            let frameCount = samples.withUnsafeMutableBufferPointer {
                phosphor_ffmpeg_audio_read(
                    work.decoder,
                    $0.baseAddress,
                    Int32(maximumFrames),
                    &presentationTime
                )
            }
            guard frameCount > 0 else {
                condition.withLock { playing = false }
                continue
            }
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
            ) else {
                continue
            }
            buffer.frameLength = AVAudioFrameCount(frameCount)
            guard let channelData = buffer.floatChannelData else {
                continue
            }
            let left = channelData[0]
            let right = channelData[1]
            samples.withUnsafeBufferPointer { source in
                for frame in 0 ..< Int(frameCount) {
                    left[frame] = source[frame * 2]
                    right[frame] = source[frame * 2 + 1]
                }
            }

            let shouldSchedule = condition.withLock {
                guard playing, generation == work.generation else { return false }
                queuedBuffers += 1
                return true
            }
            guard shouldSchedule else { continue }
            playerNode.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
                guard let self else { return }
                self.condition.withLock {
                    self.queuedBuffers = max(self.queuedBuffers - 1, 0)
                    self.condition.signal()
                }
            }
        }
        if let decoder {
            phosphor_ffmpeg_audio_close(decoder)
            self.decoder = nil
        }
    }
}

@MainActor
final class FFmpegPlaybackSession {
    let frameSource: FFmpegVideoFrameSource
    let duration: TimeInterval
    let nominalFrameRate: Float
    let scanMetadata: VideoScanMetadata
    let colorMetadata: VideoColorMetadata

    private let clock: FFmpegPlaybackClock
    private let audioOutput: FFmpegAudioOutput?
    private(set) var isPlaying = false

    init(url: URL) throws {
        var info = PhosphorFFmpegMediaInfo()
        var errorBytes = [CChar](repeating: 0, count: 512)
        let videoDecoder = url.withUnsafeFileSystemRepresentation { path in
            phosphor_ffmpeg_video_open(
                path,
                &info,
                &errorBytes,
                errorBytes.count
            )
        }
        guard let videoDecoder else {
            let bytes = errorBytes
                .prefix { $0 != 0 }
                .map { UInt8(bitPattern: $0) }
            throw FFmpegPlaybackError.unavailable(
                String(decoding: bytes, as: UTF8.self)
            )
        }

        clock = FFmpegPlaybackClock()
        frameSource = FFmpegVideoFrameSource(decoder: videoDecoder, clock: clock)
        duration = max(info.duration, 0)
        nominalFrameRate = Float(max(info.nominal_frame_rate, 0))
        scanMetadata = VideoScanMetadata(
            fieldOrder: info.is_interlaced
                ? (info.is_bottom_field_first ? .bottomFirst : .topFirst)
                : .progressive
        )
        colorMetadata = VideoColorMetadata(containsHDRVideo: info.is_hdr)

        var audioDecoder: OpaquePointer?
        if info.has_audio {
            audioDecoder = url.withUnsafeFileSystemRepresentation { path in
                phosphor_ffmpeg_audio_open(
                    path,
                    &errorBytes,
                    errorBytes.count
                )
            }
        }
        audioOutput = FFmpegAudioOutput(decoder: audioDecoder)
    }

    deinit {
        frameSource.shutdown()
        audioOutput?.shutdown()
    }

    var currentTime: TimeInterval {
        min(clock.currentTime(), duration > 0 ? duration : .greatestFiniteMagnitude)
    }

    var volume: Float {
        get { audioOutput?.volume ?? 1 }
        set { audioOutput?.volume = newValue }
    }

    func play() {
        isPlaying = true
        clock.play()
        audioOutput?.play()
    }

    func pause() {
        isPlaying = false
        clock.pause()
        audioOutput?.pause()
    }

    func seek(to time: TimeInterval) {
        let target = min(max(time, 0), duration > 0 ? duration : time)
        clock.seek(to: target)
        frameSource.seek(to: target)
        audioOutput?.seek(to: target, resume: isPlaying)
    }
}
