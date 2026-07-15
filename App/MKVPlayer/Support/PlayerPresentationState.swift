import Foundation

struct PlayerTrackOption: Equatable, Sendable {
    let id: Int64
    let title: String
    let detail: String?
    let isSelected: Bool
}

struct PlayerChapterOption: Equatable, Sendable {
    let index: Int
    let title: String
    let time: TimeInterval
    let isSelected: Bool
}

struct PlayerRecoverableErrorPresentation: Equatable, Sendable {
    let message: String
    let diagnostics: String
}

struct PlayerQueueItemPresentation: Equatable, Sendable {
    let id: UUID
    let url: URL
    let isCurrent: Bool

    var title: String { url.lastPathComponent }
}

enum PlayerPresentationPhase: Equatable, Sendable {
    case idle
    case loading
    case ready
    case playing
    case paused
    case ended
    case failed(String)
}

enum VideoPresentationScaling: Equatable, Sendable {
    case fit
    case fill
    case actualSize
}

struct PlayerPresentationState: Equatable, Sendable {
    var phase: PlayerPresentationPhase = .idle
    var fileURL: URL?
    var title: String = "MKV Player"
    var position: TimeInterval = 0
    var duration: TimeInterval = 0
    var isSeekable = false
    var volume: Double = 100
    var isMuted = false
    var rate: Double = 1
    var isBuffering = false
    var videoScaling: VideoPresentationScaling = .fit
    var naturalVideoWidth: Int?
    var naturalVideoHeight: Int?
    var isFullScreen = false
    var audioTracks: [PlayerTrackOption] = []
    var subtitleTracks: [PlayerTrackOption] = []
    var chapters: [PlayerChapterOption] = []
    var queueItems: [PlayerQueueItemPresentation] = []
    var recoverableError: PlayerRecoverableErrorPresentation?
    var diagnostics: String?

    var hasMedia: Bool { fileURL != nil }
    var hasQueue: Bool { queueItems.count > 1 }
    var currentQueueIndex: Int? { queueItems.firstIndex(where: \.isCurrent) }
    var canPlayPreviousQueueItem: Bool { (currentQueueIndex ?? 0) > 0 }
    var canPlayNextQueueItem: Bool {
        guard let currentQueueIndex else { return false }
        return queueItems.indices.contains(currentQueueIndex + 1)
    }
    var isPlaying: Bool { phase == .playing }
    var canControlPlayback: Bool {
        switch phase {
        case .ready, .playing, .paused, .ended: true
        case .idle, .loading, .failed: false
        }
    }
    var canSeek: Bool {
        canControlPlayback && isSeekable && duration.isFinite && duration > 0
    }

    func seekTarget(by offset: TimeInterval) -> TimeInterval? {
        guard canSeek, offset.isFinite, position.isFinite else { return nil }
        return min(max(position + offset, 0), duration)
    }
}

enum PlaybackRateOptions {
    static let all: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    static func label(for rate: Double) -> String {
        var value = String(
            format: "%.2f",
            locale: Locale(identifier: "en_US_POSIX"),
            rate
        )
        while value.last == "0" { value.removeLast() }
        if value.last == "." { value.removeLast() }
        return "\(value)×"
    }
}

enum TimeText {
    static func format(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "–:––" }
        let total = Int(time.rounded(.down))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
