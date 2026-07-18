import AppKit
import AVFoundation
import CoreVideo
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

    @ObservationIgnored
    private var timeObserver: PlayerTimeObserver?

    @ObservationIgnored
    private var loadGeneration = 0

    var hasMedia: Bool {
        currentURL != nil
    }

    init(player: AVPlayer = AVPlayer()) {
        self.player = player
        player.volume = volume
        timeObserver = PlayerTimeObserver(player: player) { [weak self] time in
            MainActor.assumeIsolated {
                self?.updateTime(time)
            }
        }
    }

    func load(url: URL) {
        loadGeneration += 1
        let generation = loadGeneration
        errorMessage = nil

        Task { [weak self] in
            await self?.load(url: url, generation: generation)
        }
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .audiovisualContent]
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

        let target = min(Self.finiteNonnegative(time), duration)
        currentTime = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    func setVolume(_ newValue: Float) {
        let sanitized = newValue.isFinite ? newValue : 1
        volume = min(max(sanitized, 0), 1)
        player.volume = volume
    }

    private func load(url: URL, generation: Int) async {
        do {
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

            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ])
            let item = AVPlayerItem(asset: asset)
            item.add(output)
            let colorMetadata = VideoColorMetadata(
                mediaCharacteristics: characteristics
            )

            guard generation == loadGeneration else { return }

            player.replaceCurrentItem(with: item)
            videoOutput = output
            currentURL = url
            currentTime = 0
            duration = Self.finiteNonnegative(loadedDuration.seconds)
            errorMessage = nil
            noticeMessage = colorMetadata.sdrPathNotice
            transport = .playing
            player.play()
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration else { return }
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

    private static func errorMessage(for error: Error) -> String {
        switch error {
        case PlayerLoadError.notPlayable:
            "This file cannot be played."
        case PlayerLoadError.noVideoTrack:
            "This file has no video track."
        default:
            "The video could not be opened."
        }
    }
}

private enum PlayerLoadError: Error {
    case notPlayable
    case noVideoTrack
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
