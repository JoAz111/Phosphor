import SwiftUI

struct ShaderInspectorView: View {
    @Binding var preferences: ControlPreferences

    var body: some View {
        ScrollView {
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
            InspectorEnumPicker(
                title: "Tube",
                selection: $preferences.tubeProfile,
                values: CRTTubeProfile.allCases,
                label: \CRTTubeProfile.displayName
            )
            InspectorEnumPicker(
                title: "Raster",
                selection: $preferences.rasterMode,
                values: CRTRasterMode.allCases,
                label: \CRTRasterMode.displayName,
                segmented: true
            )
            InspectorEnumPicker(
                title: "Signal",
                selection: $preferences.signalType,
                values: CRTSignalType.allCases,
                label: \CRTSignalType.displayName
            )
            InspectorSlider(
                title: "Beam Scanlines",
                value: $preferences.scanlines,
                range: 0 ... 1
            )
            InspectorMaskPatternPicker(pattern: $preferences.maskPattern)
            InspectorSlider(
                title: "Mask Strength",
                value: $preferences.mask,
                range: 0 ... 1
            )
            InspectorSlider(
                title: "Tube Glow",
                value: $preferences.glow,
                range: 0 ... 1
            )
            InspectorSlider(
                title: "Phosphor Persistence",
                value: $preferences.persistence,
                range: 0 ... 1
            )
            InspectorSlider(
                title: "Edge Convergence",
                value: $preferences.convergence,
                range: 0 ... 1
            )
            InspectorSlider(
                title: "Edge Focus",
                value: $preferences.focus,
                range: 0 ... 1
            )
            InspectorSlider(
                title: "Vignette",
                value: $preferences.vignette,
                range: 0 ... 1
            )
            Toggle("EDR Phosphors", isOn: $preferences.edrPhosphors)
                .font(.caption)
                .help("Use extended display brightness for luminous phosphors when supported")
            }
        }
        .padding(16)
        .frame(width: 310, height: 570)
        .tint(Color.phosphorGreen)
    }
}

private struct InspectorEnumPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let values: [Value]
    let label: KeyPath<Value, String>
    var segmented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)

            if segmented {
                Picker(title, selection: $selection) {
                    ForEach(values, id: \.self) { value in
                        Text(value[keyPath: label]).tag(value)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .accessibilityLabel(title)
                .accessibilityValue(selection[keyPath: label])
            } else {
                Picker(title, selection: $selection) {
                    ForEach(values, id: \.self) { value in
                        Text(value[keyPath: label]).tag(value)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityLabel(title)
                .accessibilityValue(selection[keyPath: label])
            }
        }
        .font(.caption)
    }
}

private struct InspectorMaskPatternPicker: View {
    @Binding var pattern: PhosphorMaskPattern

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Mask Pattern")

            Picker("Mask Pattern", selection: $pattern) {
                ForEach(PhosphorMaskPattern.allCases) { pattern in
                    Text(pattern.displayName).tag(pattern)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .accessibilityLabel("Mask Pattern")
            .accessibilityValue(pattern.displayName)
        }
        .font(.caption)
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
