import AVFoundation
import SwiftUI

struct MetalVideoRepresentable: NSViewRepresentable {
    let output: AVPlayerItemVideoOutput?
    let settings: ShaderSettings
    let active: Bool

    func makeNSView(context: Context) -> MetalVideoView {
        let view = MetalVideoView(frame: .zero)
        view.configure(output: output, settings: settings)
        view.setActive(active)
        return view
    }

    func updateNSView(_ nsView: MetalVideoView, context: Context) {
        nsView.configure(output: output, settings: settings)
        nsView.setActive(active)
    }

    static func dismantleNSView(
        _ nsView: MetalVideoView,
        coordinator: Void
    ) {
        nsView.setActive(false)
    }
}
