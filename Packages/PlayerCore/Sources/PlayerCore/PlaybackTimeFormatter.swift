import Foundation

public enum PlaybackTimeFormatter {
    /// Formats finite durations as `m:ss` or `h:mm:ss`. Invalid values use an em dash placeholder.
    public static func string(from interval: TimeInterval, alwaysShowHours: Bool = false) -> String {
        guard interval.isFinite, interval >= 0 else {
            return "—:——"
        }

        let totalSeconds = Int(interval.rounded(.down))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 || alwaysShowHours {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    public static func remainingString(from interval: TimeInterval) -> String {
        guard interval.isFinite, interval >= 0 else {
            return "−—:——"
        }
        return "−" + string(from: interval)
    }
}
