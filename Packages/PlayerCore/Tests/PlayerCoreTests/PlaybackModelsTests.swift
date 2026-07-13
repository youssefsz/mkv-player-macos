import Foundation
import XCTest
@testable import PlayerCore

final class PlaybackModelsTests: XCTestCase {
    func testSnapshotSanitizesUnsafeNumericValues() {
        let snapshot = PlayerSnapshot(
            currentTime: .infinity,
            duration: -.infinity,
            volume: 4,
            rate: .nan
        )

        XCTAssertEqual(snapshot.currentTime, 0)
        XCTAssertEqual(snapshot.duration, 0)
        XCTAssertEqual(snapshot.volume, 1)
        XCTAssertEqual(snapshot.rate, 1)
    }

    func testTrackSelectionAndDisplayNames() {
        let audio = TrackDescriptor(
            id: 7,
            kind: .audio,
            title: "Director Commentary",
            isSelected: true
        )
        let subtitle = TrackDescriptor(id: 9, kind: .subtitle)
        let snapshot = PlayerSnapshot(tracks: [audio, subtitle])

        XCTAssertEqual(snapshot.selectedTrackID(for: .audio), 7)
        XCTAssertNil(snapshot.selectedTrackID(for: .video))
        XCTAssertEqual(audio.displayName, "Director Commentary")
        XCTAssertEqual(subtitle.displayName, "Subtitle 9")
    }

    func testMediaLoadRequestDropsInvalidStartPositions() {
        let url = URL(fileURLWithPath: "/tmp/movie.mkv")

        XCTAssertNil(MediaLoadRequest(url: url, startPosition: -.infinity).startPosition)
        XCTAssertNil(MediaLoadRequest(url: url, startPosition: 0).startPosition)
        XCTAssertEqual(MediaLoadRequest(url: url, startPosition: 42).startPosition, 42)
    }

    func testPlaybackErrorPreservesExistingPlaybackError() {
        let original = PlaybackError(code: .corruptMedia, message: "Broken stream")

        XCTAssertEqual(PlaybackError.wrapping(original), original)
    }

    func testVideoDimensionsRejectInvalidPixelSizes() {
        XCTAssertEqual(VideoDimensions(width: 1_920, height: 1_080)?.width, 1_920)
        XCTAssertNil(VideoDimensions(width: 0, height: 1_080))
        XCTAssertNil(VideoDimensions(width: 1_920, height: -1))
    }
}

final class PlaybackTimeFormatterTests: XCTestCase {
    func testFormatsMinutesAndHours() {
        XCTAssertEqual(PlaybackTimeFormatter.string(from: 0), "0:00")
        XCTAssertEqual(PlaybackTimeFormatter.string(from: 65.9), "1:05")
        XCTAssertEqual(PlaybackTimeFormatter.string(from: 3_661), "1:01:01")
        XCTAssertEqual(PlaybackTimeFormatter.string(from: 65, alwaysShowHours: true), "0:01:05")
    }

    func testFormatsRemainingAndInvalidTimes() {
        XCTAssertEqual(PlaybackTimeFormatter.remainingString(from: 65), "−1:05")
        XCTAssertEqual(PlaybackTimeFormatter.string(from: .nan), "—:——")
        XCTAssertEqual(PlaybackTimeFormatter.string(from: -1), "—:——")
        XCTAssertEqual(PlaybackTimeFormatter.remainingString(from: .infinity), "−—:——")
    }
}

final class ResumePolicyTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/tmp/movie.mkv")

    func testResumesOnlyInsideConfiguredWindow() {
        let policy = ResumePolicy()

        XCTAssertNil(policy.resumePosition(for: entry(position: 29, duration: 500)))
        XCTAssertNil(policy.resumePosition(for: entry(position: 30, duration: 500)))
        XCTAssertEqual(policy.resumePosition(for: entry(position: 31, duration: 500)), 31)
        XCTAssertEqual(policy.resumePosition(for: entry(position: 469, duration: 500)), 469)
        XCTAssertNil(policy.resumePosition(for: entry(position: 470, duration: 500)))
        XCTAssertNil(policy.resumePosition(for: entry(position: 100, duration: nil)))
    }

    func testCompletedMediaNeverResumes() {
        let policy = ResumePolicy()
        XCTAssertNil(
            policy.resumePosition(
                for: entry(position: 100, duration: 500, isCompleted: true)
            )
        )
    }

    private func entry(
        position: TimeInterval,
        duration: TimeInterval?,
        isCompleted: Bool = false
    ) -> PlaybackHistoryEntry {
        PlaybackHistoryEntry(
            url: url,
            position: position,
            duration: duration,
            isCompleted: isCompleted
        )
    }
}
