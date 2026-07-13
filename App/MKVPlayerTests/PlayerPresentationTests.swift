import AppKit
import Foundation
import PlayerCore
import XCTest
@testable import MKV_Player

final class PlayerPresentationTests: XCTestCase {
    func testEmptySnapshotMapsToNativeEmptyState() {
        let state = PlayerPresentationState(
            snapshot: .empty,
            displayedPosition: 0,
            error: nil
        )

        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(state.title, "MKV Player")
        XCTAssertFalse(state.hasMedia)
        XCTAssertFalse(state.canSeek)
    }

    func testSnapshotMapsPlaybackMetadataAndSelections() {
        let mediaURL = URL(fileURLWithPath: "/tmp/example.mkv")
        let snapshot = PlayerSnapshot(
            phase: .paused,
            mediaURL: mediaURL,
            currentTime: 65,
            duration: 300,
            isSeekable: true,
            isBuffering: true,
            videoScaling: .fill,
            naturalVideoSize: VideoDimensions(width: 1920, height: 1080),
            volume: 0.42,
            isMuted: true,
            rate: 1.25,
            tracks: [
                TrackDescriptor(
                    id: 2,
                    kind: .audio,
                    title: "Director Commentary",
                    languageCode: "en",
                    codec: "aac",
                    isSelected: true
                ),
                TrackDescriptor(
                    id: 4,
                    kind: .subtitle,
                    languageCode: "fr",
                    codec: "ass"
                )
            ],
            chapters: [
                ChapterDescriptor(index: 0, title: "Opening", startTime: 0),
                ChapterDescriptor(index: 1, title: "Second Act", startTime: 60)
            ]
        )

        let state = PlayerPresentationState(
            snapshot: snapshot,
            displayedPosition: 65,
            error: nil
        )

        XCTAssertEqual(state.phase, .paused)
        XCTAssertEqual(state.fileURL, mediaURL)
        XCTAssertEqual(state.title, "example.mkv")
        XCTAssertEqual(state.position, 65)
        XCTAssertEqual(state.duration, 300)
        XCTAssertTrue(state.canSeek)
        XCTAssertEqual(state.volume, 42, accuracy: 0.001)
        XCTAssertTrue(state.isMuted)
        XCTAssertTrue(state.isBuffering)
        XCTAssertEqual(state.videoScaling, .fill)
        XCTAssertEqual(state.naturalVideoWidth, 1920)
        XCTAssertEqual(state.naturalVideoHeight, 1080)
        XCTAssertEqual(state.audioTracks.first?.title, "Director Commentary")
        XCTAssertEqual(state.audioTracks.first?.detail, "en · aac")
        XCTAssertEqual(state.subtitleTracks.first?.detail, "fr · ass")
        XCTAssertEqual(state.chapters.map(\.isSelected), [false, true])
    }

    func testKnownDurationDoesNotEnableSeekingWhenMediaIsNotSeekable() {
        let snapshot = PlayerSnapshot(
            phase: .playing,
            mediaURL: URL(fileURLWithPath: "/tmp/live.mkv"),
            duration: 120,
            isSeekable: false
        )

        let state = PlayerPresentationState(
            snapshot: snapshot,
            displayedPosition: 20,
            error: nil
        )

        XCTAssertFalse(state.canSeek)
    }

    func testFailureIncludesSafeDiagnostics() {
        let error = PlaybackError(
            code: .corruptMedia,
            message: "The video is damaged.",
            diagnostics: "libmpv error -12"
        )
        let snapshot = PlayerSnapshot(
            phase: .failed,
            mediaURL: URL(fileURLWithPath: "/tmp/damaged.mkv")
        )

        let state = PlayerPresentationState(
            snapshot: snapshot,
            displayedPosition: 0,
            error: error
        )

        XCTAssertEqual(state.phase, .failed("The video is damaged."))
        XCTAssertEqual(state.diagnostics, "The video is damaged.\nlibmpv error -12")
    }

    func testTimeTextUsesCompactNativePlayerFormatting() {
        XCTAssertEqual(TimeText.format(0), "0:00")
        XCTAssertEqual(TimeText.format(65.9), "1:05")
        XCTAssertEqual(TimeText.format(3_661), "1:01:01")
        XCTAssertEqual(TimeText.format(.infinity), "–:––")
    }

    @MainActor
    func testUpdateSettingsUsesLiveSchedulerSetter() {
        var appliedValues: [Bool] = []
        let model = UpdateSettingsModel(initialValue: false) { value in
            appliedValues.append(value)
        }

        model.automaticallyChecksForUpdates = true
        model.automaticallyChecksForUpdates = false

        XCTAssertEqual(appliedValues, [true, false])
    }

    @MainActor
    func testActionDrivenTimelineChangeBeginsAndCommitsScrubbing() {
        let slider = TrackingSlider(value: 0, minValue: 0, maxValue: 100)
        var trackingChanges: [Bool] = []
        var previewedValue: Double?
        var committedValue: Double?
        slider.trackingChanged = { trackingChanges.append($0) }
        slider.valueChanged = { previewedValue = $0 }
        slider.committed = { committedValue = $0 }

        slider.doubleValue = 42
        _ = slider.sendAction(slider.action, to: slider.target)

        XCTAssertEqual(trackingChanges, [true, false])
        XCTAssertEqual(previewedValue, 42)
        XCTAssertEqual(committedValue, 42)
    }

    @MainActor
    func testFocusedNativeControlsKeepSpaceAndArrowKeyHandling() {
        XCTAssertFalse(PlayerWindow.routesPlaybackShortcuts(when: NSButton()))
        XCTAssertFalse(PlayerWindow.routesPlaybackShortcuts(when: NSSlider()))
        XCTAssertFalse(PlayerWindow.routesPlaybackShortcuts(when: NSTextView()))
        XCTAssertTrue(PlayerWindow.routesPlaybackShortcuts(when: NSView()))
    }

    @MainActor
    func testTransportAvailabilityAndFullScreenLabelFollowPresentation() throws {
        let controls = PlaybackControlsView(frame: .zero)
        var state = PlayerPresentationState(
            phase: .loading,
            fileURL: URL(fileURLWithPath: "/tmp/loading.mkv"),
            duration: 120,
            isSeekable: true
        )
        controls.render(state)

        let play = try XCTUnwrap(descendants(of: controls, as: ActionButton.self).first { $0.toolTip == "Play or Pause" })
        let back = try XCTUnwrap(descendants(of: controls, as: ActionButton.self).first { $0.toolTip == "Back 10 Seconds" })
        XCTAssertFalse(play.isEnabled)
        XCTAssertFalse(back.isEnabled)

        state.phase = .paused
        state.isFullScreen = true
        controls.render(state)

        let fullScreen = try XCTUnwrap(descendants(of: controls, as: ActionButton.self).first {
            $0.toolTip == "Exit Full Screen"
        })
        XCTAssertTrue(play.isEnabled)
        XCTAssertTrue(back.isEnabled)
        XCTAssertEqual(fullScreen.toolTip, "Exit Full Screen")
    }

    @MainActor
    func testRecoverableErrorRemainsNonFatalAndDismissible() throws {
        let canvas = PlayerCanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        let state = PlayerPresentationState(
            phase: .playing,
            fileURL: URL(fileURLWithPath: "/tmp/playing.mkv"),
            duration: 120,
            isSeekable: true,
            recoverableError: PlayerRecoverableErrorPresentation(
                message: "The subtitle could not be loaded.",
                diagnostics: "sub-add failed"
            )
        )

        canvas.render(state)

        let errorView = try XCTUnwrap(descendants(of: canvas, as: ErrorStateView.self).first)
        let dismiss = try XCTUnwrap(descendants(of: errorView, as: NSButton.self).first { $0.title == "Dismiss" })
        let chooseAnother = try XCTUnwrap(descendants(of: errorView, as: NSButton.self).first {
            $0.title == "Choose Another Video…"
        })
        XCTAssertEqual(state.phase, .playing)
        XCTAssertFalse(errorView.isHidden)
        XCTAssertFalse(dismiss.isHidden)
        XCTAssertTrue(chooseAnother.isHidden)
    }

    @MainActor
    func testResumeBannerExposesAnnouncementText() {
        let banner = ResumeBannerView(frame: .zero)
        let message = banner.show(position: 65)

        XCTAssertEqual(message, "Resumed at 1:05")
        XCTAssertFalse(banner.isHidden)
        XCTAssertEqual(banner.accessibilityLabel(), message)
    }

    @MainActor
    func testAppMenuDoesNotRebuildStaticSectionsForPositionTicks() {
        _ = NSApplication.shared
        let previousMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = previousMenu }
        let target = NSObject()
        let controller = AppMenuController(commandTarget: target)
        var state = PlayerPresentationState()

        controller.refresh(state: state, recentURLs: [])
        let initialRevision = controller.contentRevision
        state.position = 1
        controller.refresh(state: state, recentURLs: [])

        XCTAssertEqual(controller.contentRevision, initialRevision)

        state.audioTracks = [
            PlayerTrackOption(id: 1, title: "English", detail: "en · aac", isSelected: true)
        ]
        controller.refresh(state: state, recentURLs: [])
        XCTAssertEqual(controller.contentRevision, initialRevision + 1)
    }

    @MainActor
    func testClearingRecentsPreservesResumeHistory() async throws {
        let mediaURL = URL(fileURLWithPath: "/tmp/history.mkv")
        let entry = PlaybackHistoryEntry(
            url: mediaURL,
            position: 75,
            duration: 300
        )
        let store = TestPlaybackHistoryStore(entries: [entry])
        let suiteName = "io.github.youssefsz.MKVPlayerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = RecentFilesController(historyStore: store, defaults: defaults)

        controller.noteOpened(mediaURL)
        let recentsBeforeClearing = await controller.loadRecentURLs()
        XCTAssertEqual(recentsBeforeClearing, [mediaURL])

        controller.clear()

        let recentsAfterClearing = await controller.loadRecentURLs()
        let preservedHistory = try await store.allEntries()
        XCTAssertEqual(recentsAfterClearing, [])
        XCTAssertEqual(preservedHistory, [entry])
    }
}

@MainActor
private func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
    view.subviews.flatMap { subview in
        (subview as? T).map { [$0] } ?? [] + descendants(of: subview, as: type)
    }
}

private actor TestPlaybackHistoryStore: PlaybackHistoryStoring {
    private var entries: [String: PlaybackHistoryEntry]

    init(entries: [PlaybackHistoryEntry]) {
        self.entries = Dictionary(uniqueKeysWithValues: entries.map { ($0.mediaKey, $0) })
    }

    func entry(for mediaKey: String) throws -> PlaybackHistoryEntry? {
        entries[mediaKey]
    }

    func allEntries() throws -> [PlaybackHistoryEntry] {
        entries.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    func upsert(_ entry: PlaybackHistoryEntry) throws {
        entries[entry.mediaKey] = entry
    }

    func remove(mediaKey: String) throws {
        entries.removeValue(forKey: mediaKey)
    }

    func removeAll() throws {
        entries.removeAll()
    }
}
