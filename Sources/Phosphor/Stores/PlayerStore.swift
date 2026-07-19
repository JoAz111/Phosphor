import AppKit
import AVFoundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class PlayerStore {
    @ObservationIgnored
    let player: AVPlayer

    @ObservationIgnored
    private(set) var videoOutput: AVPlayerItemVideoOutput?

    @ObservationIgnored
    private(set) var frameSource: (any VideoFrameSource)?

    private(set) var transport: PlayerTransport = .empty
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var nominalFrameRate: Float = 0
    private(set) var scanMetadata: VideoScanMetadata = .progressive
    private(set) var volume: Float = 1
    private(set) var currentURL: URL?
    private(set) var errorMessage: String?
    private(set) var noticeMessage: String?
    private(set) var isLoading = false

    @ObservationIgnored
    private var timeObserver: PlayerTimeObserver?

    @ObservationIgnored
    private var directPlaybackSession: FFmpegPlaybackSession?

    @ObservationIgnored
    private var directTimeTask: Task<Void, Never>?

    @ObservationIgnored
    private var loadGeneration = 0

    @ObservationIgnored
    private var currentLoadTask: Task<Void, Never>?

    @ObservationIgnored
    private let assetLoader: PlayerAssetLoading

    var hasMedia: Bool {
        currentURL != nil
    }

    init(
        player: AVPlayer = AVPlayer(),
        assetLoader: @escaping PlayerAssetLoading = AdaptivePlayerAssetLoader.load(url:)
    ) {
        self.player = player
        self.assetLoader = assetLoader
        player.volume = volume
        timeObserver = PlayerTimeObserver(player: player) { [weak self] time in
            Task { @MainActor [weak self] in
                self?.updateTime(time)
            }
        }
    }

    deinit {
        directTimeTask?.cancel()
    }

    @discardableResult
    func load(url: URL) -> Task<Void, Never> {
        currentLoadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        errorMessage = nil
        isLoading = true

        let task = Task { [weak self] in
            guard let self else { return }
            await self.load(url: url, generation: generation)
        }
        currentLoadTask = task
        return task
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .audiovisualContent]
        panel.allowsOtherFileTypes = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url: url)
    }

    func togglePlayback() {
        transport = transport.toggled(hasMedia: hasMedia)

        switch transport {
        case .playing:
            if let directPlaybackSession {
                directPlaybackSession.play()
            } else {
                player.play()
            }
        case .empty, .paused:
            player.pause()
            directPlaybackSession?.pause()
        }
    }

    func seek(to time: TimeInterval) {
        guard hasMedia else { return }

        let target = Self.clamped(time, upperBound: duration, nanDefault: 0)
        currentTime = target
        if let directPlaybackSession {
            directPlaybackSession.seek(to: target)
        } else {
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        }
    }

    func setVolume(_ newValue: Float) {
        let sanitized = newValue.isNaN ? 1 : newValue
        volume = min(max(sanitized, 0), 1)
        player.volume = volume
        directPlaybackSession?.volume = volume
    }

    private func load(url: URL, generation: Int) async {
        do {
            let prepared = try await assetLoader(url)

            guard generation == loadGeneration else { return }

            directPlaybackSession?.pause()
            directPlaybackSession = prepared.ffmpegSession
            synchronizeDirectTimeTask()
            player.replaceCurrentItem(with: prepared.item)
            videoOutput = prepared.output
            frameSource = prepared.frameSource
            currentURL = url
            currentTime = 0
            duration = Self.finiteNonnegative(prepared.duration)
            nominalFrameRate = Self.finiteNonnegative(prepared.nominalFrameRate)
            scanMetadata = prepared.scanMetadata
            errorMessage = nil
            noticeMessage = prepared.colorMetadata.sdrPathNotice
            if let preparationNotice = prepared.preparation.notice {
                noticeMessage = [noticeMessage, preparationNotice]
                    .compactMap { $0 }
                    .joined(separator: " ")
            }
            transport = .playing
            isLoading = false
            if let directPlaybackSession {
                directPlaybackSession.volume = volume
                directPlaybackSession.play()
            } else {
                player.play()
            }
        } catch is CancellationError {
            if generation == loadGeneration {
                isLoading = false
            }
            return
        } catch {
            guard generation == loadGeneration else { return }
            isLoading = false
            errorMessage = Self.errorMessage(for: error)
        }
    }

    private func updateTime(_ time: CMTime) {
        guard hasMedia, directPlaybackSession == nil else { return }

        currentTime = Self.finiteNonnegative(time.seconds)
        if let item = player.currentItem {
            let itemDuration = Self.finiteNonnegative(item.duration.seconds)
            if itemDuration > 0 {
                duration = itemDuration
            }
        }
    }

    private func updateDirectPlaybackTime() {
        guard let directPlaybackSession, hasMedia else { return }
        currentTime = Self.finiteNonnegative(directPlaybackSession.currentTime)
        if duration > 0, currentTime >= duration, transport == .playing {
            directPlaybackSession.pause()
            transport = .paused
        }
    }

    private func synchronizeDirectTimeTask() {
        directTimeTask?.cancel()
        directTimeTask = nil
        guard directPlaybackSession != nil else { return }

        directTimeTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                self?.updateDirectPlaybackTime()
            }
        }
    }

    private static func finiteNonnegative(_ value: TimeInterval) -> TimeInterval {
        value.isFinite ? max(value, 0) : 0
    }

    private static func finiteNonnegative(_ value: Float) -> Float {
        value.isFinite ? max(value, 0) : 0
    }

    private static func clamped(
        _ value: TimeInterval,
        upperBound: TimeInterval,
        nanDefault: TimeInterval
    ) -> TimeInterval {
        let sanitized = value.isNaN ? nanDefault : value
        return min(max(sanitized, 0), upperBound)
    }

    private static func errorMessage(for error: Error) -> String {
        switch error {
        case PlayerLoadError.notPlayable:
            "This file cannot be played."
        case PlayerLoadError.noVideoTrack:
            "This file has no video track."
        case PlayerLoadError.ffmpegFailed:
            "Bundled FFmpeg could not decode this video."
        default:
            "The video could not be opened."
        }
    }
}

private final class PlayerTimeObserver {
    private let player: AVPlayer
    private var token: Any?

    init(
        player: AVPlayer,
        handler: @escaping @Sendable (CMTime) -> Void
    ) {
        self.player = player
        token = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main,
            using: handler
        )
    }

    deinit {
        if let token {
            player.removeTimeObserver(token)
        }
    }
}
