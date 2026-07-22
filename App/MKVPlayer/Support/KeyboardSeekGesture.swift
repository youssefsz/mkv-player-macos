import Foundation

/// Accumulates rapid keyboard seek steps into one gesture so the HUD can show
/// +5 → +10 → +15 and seeks stack from a stable anchor position.
struct KeyboardSeekGesture: Equatable, Sendable {
    static let defaultWindow: TimeInterval = 0.75

    private(set) var anchor: TimeInterval?
    private(set) var accumulated: TimeInterval = 0
    private(set) var windowEnd: Date?

    mutating func reset() {
        anchor = nil
        accumulated = 0
        windowEnd = nil
    }

    mutating func apply(
        step: TimeInterval,
        position: TimeInterval,
        duration: TimeInterval,
        now: Date = Date(),
        window: TimeInterval = Self.defaultWindow
    ) -> (target: TimeInterval, displayedOffset: TimeInterval)? {
        guard step.isFinite, step != 0,
              position.isFinite, duration.isFinite, duration > 0 else {
            return nil
        }

        let isActive = windowEnd.map { now <= $0 } == true
        let directionChanged = accumulated != 0 && step.sign != accumulated.sign
        if !isActive || directionChanged || anchor == nil {
            anchor = position
            accumulated = 0
        }

        guard let anchor else { return nil }

        let desired = anchor + accumulated + step
        let target = min(max(desired, 0), duration)
        let displayedOffset = target - anchor
        guard displayedOffset != accumulated else { return nil }

        accumulated = displayedOffset
        windowEnd = now.addingTimeInterval(window)
        return (target, displayedOffset)
    }
}
