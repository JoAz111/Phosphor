enum PlayerTransport: Equatable, Sendable {
    case empty
    case paused
    case playing

    func toggled(hasMedia: Bool) -> PlayerTransport {
        guard hasMedia else { return .empty }

        switch self {
        case .playing:
            return .paused
        case .empty, .paused:
            return .playing
        }
    }
}
