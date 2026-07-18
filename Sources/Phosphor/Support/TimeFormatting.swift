import Foundation

enum TimeFormatting {
    static func playerTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < TimeInterval(Int.max) else {
            return "0:00"
        }

        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let remainingSeconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }
}
