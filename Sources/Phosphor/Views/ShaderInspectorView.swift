import SwiftUI

struct ShaderInspectorView: View {
    @Binding var preferences: ControlPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("CRT Settings")
                    .font(.headline)

                Spacer()

                Button("Reset") {
                    preferences.reset()
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Reset CRT Settings")
            }

            InspectorSlider(
                title: "Curvature",
                value: $preferences.curvature,
                range: 0 ... 0.25
            )
            InspectorSlider(
                title: "Beam Scanlines",
                value: $preferences.scanlines,
                range: 0 ... 1
            )
            InspectorSlider(
                title: "Phosphor Mask",
                value: $preferences.mask,
                range: 0 ... 1
            )
            InspectorSlider(
                title: "Tube Glow",
                value: $preferences.glow,
                range: 0 ... 1
            )
            InspectorSlider(
                title: "Vignette",
                value: $preferences.vignette,
                range: 0 ... 1
            )
        }
        .padding(16)
        .frame(width: 280)
        .tint(Color.phosphorGreen)
    }
}

private struct InspectorSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text(value, format: .number.precision(.fractionLength(2)))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Slider(value: $value, in: range)
                .accessibilityLabel(title)
                .accessibilityValue(
                    Text(value, format: .number.precision(.fractionLength(2)))
                )
        }
        .font(.caption)
    }
}
