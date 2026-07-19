import AppKit
import SwiftUI

enum ControlPresentation {
    static let fullScreenActionLabel = "Toggle Full Screen"
}

struct ControlPreferences: Equatable {
    var isBypassed: Bool
    var savedIntensity: Double
    var curvature: Double
    var scanlines: Double
    var mask: Double
    var maskPattern: PhosphorMaskPattern
    var glow: Double
    var vignette: Double
    var edrPhosphors: Bool

    static let `default` = ControlPreferences()

    var shaderSettings: ShaderSettings {
        ShaderSettings(
            intensity: isBypassed ? 0 : Float(savedIntensity),
            curvature: Float(curvature),
            scanlines: Float(scanlines),
            mask: Float(mask),
            maskPattern: maskPattern,
            glow: Float(glow),
            vignette: Float(vignette)
        )
    }

    init(
        isBypassed: Bool = false,
        savedIntensity: Double = Double(ShaderSettings.default.intensity),
        curvature: Double = Double(ShaderSettings.default.curvature),
        scanlines: Double = Double(ShaderSettings.default.scanlines),
        mask: Double = Double(ShaderSettings.default.mask),
        maskPattern: PhosphorMaskPattern = ShaderSettings.default.maskPattern,
        glow: Double = Double(ShaderSettings.default.glow),
        vignette: Double = Double(ShaderSettings.default.vignette),
        edrPhosphors: Bool = true
    ) {
        self.isBypassed = isBypassed
        self.savedIntensity = savedIntensity
        self.curvature = curvature
        self.scanlines = scanlines
        self.mask = mask
        self.maskPattern = maskPattern
        self.glow = glow
        self.vignette = vignette
        self.edrPhosphors = edrPhosphors
    }

    mutating func reset() {
        self = .default
    }
}

struct PlayerControlsView: View {
    let store: PlayerStore
    @Binding var preferences: ControlPreferences
    @Binding var isScrubbing: Bool
    @Binding var isAdvancedInteractionActive: Bool

    @State private var seekDraft: Double = 0
    @State private var isInspectorPresented = false

    var body: some View {
        HStack(spacing: 9) {
            Button {
                store.togglePlayback()
            } label: {
                Image(systemName: store.transport == .playing ? "pause.fill" : "play.fill")
            }
            .frame(width: 20)
            .accessibilityLabel(store.transport == .playing ? "Pause" : "Play")
            .help(store.transport == .playing ? "Pause" : "Play")

            Text(timeLabel)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .truncationMode(.middle)
                .frame(width: 92, alignment: .leading)
                .accessibilityLabel("Playback time \(timeLabel)")

            Slider(
                value: seekBinding,
                in: 0 ... max(store.duration, 1),
                onEditingChanged: updateScrubbing
            )
            .frame(width: 140)
            .disabled(store.duration <= 0)
            .accessibilityLabel("Playback position")
            .accessibilityValue(TimeFormatting.playerTime(seekBinding.wrappedValue))

            Image(systemName: volumeSymbol)
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)

            Slider(value: volumeBinding, in: 0 ... 1)
                .frame(width: 64)
                .accessibilityLabel("Volume")
                .accessibilityValue("\(Int(store.volume * 100)) percent")

            Divider()
                .frame(width: 1, height: 18)

            Toggle(isOn: $preferences.isBypassed) {
                Image(systemName: "rectangle.on.rectangle.slash")
            }
            .toggleStyle(.button)
            .labelStyle(.iconOnly)
            .frame(width: 24)
            .accessibilityLabel("Bypass CRT Effect")
            .help("Bypass CRT Effect")

            Image(systemName: "sparkles")
                .foregroundStyle(preferences.isBypassed ? .secondary : Color.phosphorGreen)
                .frame(width: 16)
                .accessibilityHidden(true)

            Slider(value: $preferences.savedIntensity, in: 0 ... 1)
                .frame(width: 64)
                .disabled(preferences.isBypassed)
                .accessibilityLabel("CRT Intensity")
                .accessibilityValue("\(Int(preferences.savedIntensity * 100)) percent")

            Button {
                isInspectorPresented.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .frame(width: 20)
            .accessibilityLabel("Advanced CRT Settings")
            .help("Advanced CRT Settings")
            .popover(isPresented: $isInspectorPresented, arrowEdge: .top) {
                ShaderInspectorView(preferences: $preferences)
            }

            Button {
                NSApp.keyWindow?.toggleFullScreen(nil)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .frame(width: 20)
            .accessibilityLabel(ControlPresentation.fullScreenActionLabel)
            .help(ControlPresentation.fullScreenActionLabel)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .tint(Color.phosphorGreen)
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.primary.opacity(0.09), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
        .onChange(of: isInspectorPresented) { _, isPresented in
            isAdvancedInteractionActive = isPresented
        }
        .onDisappear {
            isAdvancedInteractionActive = false
        }
    }

    private var timeLabel: String {
        "\(TimeFormatting.playerTime(displayedTime)) / \(TimeFormatting.playerTime(store.duration))"
    }

    private var displayedTime: TimeInterval {
        isScrubbing ? seekDraft : store.currentTime
    }

    private var seekBinding: Binding<Double> {
        Binding(
            get: { displayedTime },
            set: { seekDraft = $0 }
        )
    }

    private var volumeBinding: Binding<Double> {
        Binding(
            get: { Double(store.volume) },
            set: { store.setVolume(Float($0)) }
        )
    }

    private var volumeSymbol: String {
        switch store.volume {
        case 0:
            "speaker.slash.fill"
        case 0 ..< 0.5:
            "speaker.wave.1.fill"
        default:
            "speaker.wave.2.fill"
        }
    }

    private func updateScrubbing(_ editing: Bool) {
        if editing {
            seekDraft = store.currentTime
            isScrubbing = true
        } else {
            store.seek(to: seekDraft)
            isScrubbing = false
        }
    }
}
