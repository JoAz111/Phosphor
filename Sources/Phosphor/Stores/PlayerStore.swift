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

    private(set) var transport: PlayerTransport = .empty
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var volume: Float = 1
    private(set) var currentURL: URL?
    private(set) var errorMessage: String?
    private(set) var noticeMessage: String?
    private(set) var isLoading = false

    @ObservationIgnored
    private var timeObserver: PlayerTimeObserver?

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
            MainActor.assumeIsolated {
                self?.updateTime(time)
            }
        }
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
            player.play()
        case .empty, .paused:
            player.pause()
        }
    }

    func seek(to time: TimeInterval) {
        guard hasMedia else { return }

        let target = Self.clamped(time, upperBound: duration, nanDefault: 0)
        currentTime = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    func setVolume(_ newValue: Float) {
        let sanitized = newValue.isNaN ? 1 : newValue
        volume = min(max(sanitized, 0), 1)
        player.volume = volume
    }

    private func load(url: URL, generation: Int) async {
        do {
            let prepared = try await assetLoader(url)

            guard generation == loadGeneration else { return }

            player.replaceCurrentItem(with: prepared.item)
            videoOutput = prepared.output
            currentURL = url
            currentTime = 0
            duration = Self.finiteNonnegative(prepared.duration)
            errorMessage = nil
            noticeMessage = prepared.colorMetadata.sdrPathNotice
            if let preparationNotice = prepared.preparation.notice {
                noticeMessage = [noticeMessage, preparationNotice]
                    .compactMap { $0 }
                    .joined(separator: " ")
            }
            transport = .playing
            isLoading = false
            player.play()
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
        guard hasMedia else { return }

        currentTime = Self.finiteNonnegative(time.seconds)
        if let item = player.currentItem {
            let itemDuration = Self.finiteNonnegative(item.duration.seconds)
            if itemDuration > 0 {
                duration = itemDuration
            }
        }
    }

    private static func finiteNonnegative(_ value: TimeInterval) -> TimeInterval {
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
        case PlayerLoadError.ffmpegUnavailable:
            "FFmpeg is required for this format. Install it with: brew install ffmpeg"
        case PlayerLoadError.ffmpegFailed:
            "FFmpeg could not prepare this video for playback."
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
