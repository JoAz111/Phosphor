import SwiftUI

struct ContentView: View {
    let store: PlayerStore

    @AppStorage("phosphor.shader.bypassed")
    private var isBypassed = ControlPreferences.default.isBypassed
    @AppStorage("phosphor.shader.intensity")
    private var savedIntensity = ControlPreferences.default.savedIntensity
    @AppStorage("phosphor.shader.curvature")
    private var curvature = ControlPreferences.default.curvature
    @AppStorage("phosphor.shader.scanlines")
    private var scanlines = ControlPreferences.default.scanlines
    @AppStorage("phosphor.shader.mask")
    private var mask = ControlPreferences.default.mask
    @AppStorage("phosphor.shader.maskPattern")
    private var maskPatternRawValue = ControlPreferences.default.maskPattern.rawValue
    @AppStorage("phosphor.shader.glow")
    private var glow = ControlPreferences.default.glow
    @AppStorage("phosphor.shader.vignette")
    private var vignette = ControlPreferences.default.vignette
    @AppStorage("phosphor.shader.persistence")
    private var persistence = ControlPreferences.default.persistence
    @AppStorage("phosphor.shader.convergence")
    private var convergence = ControlPreferences.default.convergence
    @AppStorage("phosphor.shader.focus")
    private var focus = ControlPreferences.default.focus
    @AppStorage("phosphor.shader.rasterMode")
    private var rasterModeRawValue = ControlPreferences.default.rasterMode.rawValue
    @AppStorage("phosphor.shader.signalType")
    private var signalTypeRawValue = ControlPreferences.default.signalType.rawValue
    @AppStorage("phosphor.shader.tubeProfile")
    private var tubeProfileRawValue = ControlPreferences.default.tubeProfile.rawValue
    @AppStorage("phosphor.display.edrPhosphors")
    private var edrPhosphors = ControlPreferences.default.edrPhosphors

    @State private var controlsAreVisible = true
    @State private var activityToken = 0
    @State private var isScrubbing = false
    @State private var isAdvancedInteractionActive = false

    var body: some View {
        ZStack {
            Color.black

            MetalVideoRepresentable(
                output: store.videoOutput,
                settings: controlPreferences.shaderSettings,
                active: store.transport == .playing,
                presentationTime: store.currentTime,
                nominalFrameRate: store.nominalFrameRate,
                scanMetadata: store.scanMetadata,
                edrPhosphors: controlPreferences.edrPhosphors
            )

            if !store.hasMedia {
                emptyState
            }

            VStack(spacing: 8) {
                if store.isLoading {
                    InlineProgressView(message: "Opening video…")
                }

                if let errorMessage = store.errorMessage {
                    InlineMessageView(
                        message: errorMessage,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                }

                if let noticeMessage = store.noticeMessage {
                    InlineMessageView(
                        message: noticeMessage,
                        systemImage: "info.circle.fill"
                    )
                }

                Spacer(minLength: 0)
            }
            .padding(16)

            if store.hasMedia, controlsAreVisible {
                VStack {
                    Spacer()
                    PlayerControlsView(
                        store: store,
                        preferences: controlPreferencesBinding,
                        isScrubbing: $isScrubbing,
                        isAdvancedInteractionActive: $isAdvancedInteractionActive
                    )
                    .padding(16)
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .onContinuousHover { phase in
            guard case .active = phase else { return }
            revealControls()
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            store.load(url: url)
            revealControls()
            return true
        }
        .onOpenURL { url in
            guard url.isFileURL else { return }
            store.load(url: url)
            revealControls()
        }
        .onChange(of: store.transport) { _, _ in
            revealControls()
        }
        .onChange(of: isScrubbing) { _, _ in
            revealControls()
        }
        .onChange(of: isAdvancedInteractionActive) { _, _ in
            revealControls()
        }
        .task(id: activityToken) {
            guard shouldAutoHideControls else { return }

            do {
                try await Task.sleep(for: .seconds(2.5))
            } catch {
                return
            }

            guard shouldAutoHideControls else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                controlsAreVisible = false
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Text("PHOSPHOR")
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .tracking(7)
                .foregroundStyle(Color.phosphorGreen.opacity(0.72))

            Button("Open Video…") {
                store.presentOpenPanel()
            }
            .buttonStyle(.bordered)
            .tint(Color.phosphorGreen.opacity(0.75))
            .accessibilityLabel("Open Video")
        }
    }

    private var shouldAutoHideControls: Bool {
        store.transport == .playing
            && !isScrubbing
            && !isAdvancedInteractionActive
    }

    private var controlPreferences: ControlPreferences {
        ControlPreferences(
            isBypassed: isBypassed,
            savedIntensity: savedIntensity,
            curvature: curvature,
            scanlines: scanlines,
            mask: mask,
            maskPattern: PhosphorMaskPattern(rawValue: maskPatternRawValue)
                ?? .apertureGrille,
            glow: glow,
            vignette: vignette,
            persistence: persistence,
            convergence: convergence,
            focus: focus,
            rasterMode: CRTRasterMode(rawValue: rasterModeRawValue)
                ?? .automatic,
            signalType: CRTSignalType(rawValue: signalTypeRawValue) ?? .rgb,
            tubeProfile: CRTTubeProfile(rawValue: tubeProfileRawValue)
                ?? .consumerTV,
            edrPhosphors: edrPhosphors
        )
    }

    private var controlPreferencesBinding: Binding<ControlPreferences> {
        Binding(
            get: { controlPreferences },
            set: { preferences in
                isBypassed = preferences.isBypassed
                savedIntensity = preferences.savedIntensity
                curvature = preferences.curvature
                scanlines = preferences.scanlines
                mask = preferences.mask
                maskPatternRawValue = preferences.maskPattern.rawValue
                glow = preferences.glow
                vignette = preferences.vignette
                persistence = preferences.persistence
                convergence = preferences.convergence
                focus = preferences.focus
                rasterModeRawValue = preferences.rasterMode.rawValue
                signalTypeRawValue = preferences.signalType.rawValue
                tubeProfileRawValue = preferences.tubeProfile.rawValue
                edrPhosphors = preferences.edrPhosphors
            }
        )
    }

    private func revealControls() {
        if !controlsAreVisible {
            withAnimation(.easeIn(duration: 0.12)) {
                controlsAreVisible = true
            }
        }
        activityToken &+= 1
    }
}

private struct InlineProgressView: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(message)
        }
        .font(.callout)
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
    }
}

private struct InlineMessageView: View {
    let message: String
    let systemImage: String

    var body: some View {
        Label(message, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .accessibilityLabel(message)
    }
}

extension Color {
    static let phosphorGreen = Color(red: 0.46, green: 0.91, blue: 0.56)
}
