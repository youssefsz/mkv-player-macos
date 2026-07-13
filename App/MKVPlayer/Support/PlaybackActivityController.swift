import Foundation

@MainActor
final class PlaybackActivityController {
    private var activity: NSObjectProtocol?

    func setPlaying(_ isPlaying: Bool) {
        if isPlaying, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "Playing video"
            )
        } else if !isPlaying, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
}
