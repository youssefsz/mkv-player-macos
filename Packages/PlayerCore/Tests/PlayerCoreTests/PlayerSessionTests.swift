import Foundation
import XCTest
@testable import PlayerCore

@MainActor
final class PlayerSessionTests: XCTestCase {
    func testConsumesEventsAndThrottlesPositionToFourHertz() async throws {
        let engine = FakePlayerEngine()
        let clock = TestDateClock()
        let session = PlayerSession(
            engine: engine,
            bookmarkProvider: nil,
            configuration: .init(positionPublishInterval: 0.25),
            now: clock.now
        )
        let url = URL(fileURLWithPath: "/tmp/movie.mkv")
        try await session.open(url)

        engine.emit(.mediaLoaded(url))
        engine.emit(.phaseChanged(.playing))
        engine.emit(.positionChanged(currentTime: 1, duration: 100))
        let consumedFirstPosition = await eventually { session.snapshot.currentTime == 1 }
        XCTAssertTrue(consumedFirstPosition)

        clock.advance(by: 0.1)
        engine.emit(.positionChanged(currentTime: 2, duration: 100))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(session.snapshot.currentTime, 1)

        clock.advance(by: 0.15)
        engine.emit(.positionChanged(currentTime: 3, duration: 100))
        let consumedThirdPosition = await eventually { session.snapshot.currentTime == 3 }
        XCTAssertTrue(consumedThirdPosition)
        XCTAssertEqual(session.phase, .playing)
        XCTAssertEqual(session.snapshot.duration, 100)
    }

    func testOpenUsesSavedResumePositionAndRestartSeeksImmediately() async throws {
        let engine = FakePlayerEngine()
        let url = URL(fileURLWithPath: "/tmp/resume.mkv")
        let history = InMemoryHistoryStore(entries: [
            PlaybackHistoryEntry(url: url, position: 90, duration: 400)
        ])
        let session = PlayerSession(
            engine: engine,
            historyStore: history,
            bookmarkProvider: FakeBookmarkProvider()
        )

        try await session.open(url, autoplay: false)

        guard case let .load(request)? = engine.commands.first else {
            return XCTFail("Expected one load command")
        }
        XCTAssertEqual(request.url, url)
        XCTAssertEqual(request.startPosition, 90)
        XCTAssertFalse(request.autoplay)
        XCTAssertEqual(session.snapshot.currentTime, 90)
        XCTAssertEqual(session.resumeNotice?.position, 90)

        try await session.restartFromBeginning()
        XCTAssertNil(session.resumeNotice)
        XCTAssertEqual(session.snapshot.currentTime, 0)
        XCTAssertEqual(engine.commands.last, .seekTo(0))
    }

    func testCompletedMediaStartsAtBeginning() async throws {
        let engine = FakePlayerEngine()
        let url = URL(fileURLWithPath: "/tmp/completed.mkv")
        let history = InMemoryHistoryStore(entries: [
            PlaybackHistoryEntry(
                url: url,
                position: 395,
                duration: 400,
                isCompleted: true
            )
        ])
        let session = PlayerSession(
            engine: engine,
            historyStore: history,
            bookmarkProvider: nil
        )

        try await session.open(url)

        guard case let .load(request)? = engine.commands.first else {
            return XCTFail("Expected one load command")
        }
        XCTAssertEqual(request.url, url)
        XCTAssertNil(request.startPosition)
        XCTAssertTrue(request.autoplay)
        XCTAssertNil(session.resumeNotice)
    }

    func testOpenCanExplicitlyIgnoreResumableHistory() async throws {
        let engine = FakePlayerEngine()
        let url = URL(fileURLWithPath: "/tmp/start-over.mkv")
        let history = InMemoryHistoryStore(entries: [
            PlaybackHistoryEntry(url: url, position: 90, duration: 400)
        ])
        let session = PlayerSession(
            engine: engine,
            historyStore: history,
            bookmarkProvider: nil
        )

        try await session.open(url, autoplay: true, allowResume: false)

        guard case let .load(request)? = engine.commands.first else {
            return XCTFail("Expected one load command")
        }
        XCTAssertEqual(request.url, url)
        XCTAssertNil(request.startPosition)
        XCTAssertTrue(request.autoplay)
        XCTAssertEqual(session.snapshot.currentTime, 0)
        XCTAssertNil(session.resumeNotice)
    }

    func testNewerOpenWinsWhenOlderHistoryLookupFinishesLate() async throws {
        let firstURL = URL(fileURLWithPath: "/tmp/slow-history.mkv")
        let secondURL = URL(fileURLWithPath: "/tmp/newer.mp4")
        let historyGate = URLSuspensionGate(suspending: [firstURL])
        let history = InMemoryHistoryStore(
            entries: [PlaybackHistoryEntry(url: firstURL, position: 90, duration: 400)],
            lookupGate: historyGate
        )
        let engine = FakePlayerEngine()
        let accessRecorder = ResourceAccessRecorder()
        let session = PlayerSession(
            engine: engine,
            historyStore: history,
            bookmarkProvider: nil,
            resourceAccessor: FakeResourceAccessor(recorder: accessRecorder)
        )

        let olderOpen = Task { @MainActor in
            try await session.open(firstURL)
        }
        await historyGate.waitUntilStarted(firstURL)

        try await session.open(secondURL)
        await historyGate.resume(firstURL)

        do {
            try await olderOpen.value
            XCTFail("The superseded open should be cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertEqual(session.currentMediaURL, secondURL)
        XCTAssertEqual(session.snapshot.currentTime, 0)
        XCTAssertNil(session.resumeNotice)
        XCTAssertNil(session.lastError)
        XCTAssertNil(session.lastPersistenceError)
        XCTAssertEqual(accessRecorder.started, [firstURL, secondURL])
        XCTAssertEqual(accessRecorder.stopped, [firstURL])
    }

    func testNewerOpenWinsWhenOlderEngineLoadFailsLate() async throws {
        let firstURL = URL(fileURLWithPath: "/tmp/slow-load.mkv")
        let secondURL = URL(fileURLWithPath: "/tmp/newer.mp4")
        let loadGate = URLSuspensionGate(suspending: [firstURL])
        let staleError = PlaybackError(code: .corruptMedia, message: "Stale failure")
        let engine = FakePlayerEngine(
            loadGate: loadGate,
            delayedLoadErrors: [firstURL: staleError]
        )
        let accessRecorder = ResourceAccessRecorder()
        let session = PlayerSession(
            engine: engine,
            bookmarkProvider: nil,
            resourceAccessor: FakeResourceAccessor(recorder: accessRecorder)
        )

        let olderOpen = Task { @MainActor in
            try await session.open(firstURL)
        }
        await loadGate.waitUntilStarted(firstURL)

        try await session.open(secondURL)
        await loadGate.resume(firstURL)

        do {
            try await olderOpen.value
            XCTFail("The superseded open should be cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertEqual(session.currentMediaURL, secondURL)
        XCTAssertNil(session.resumeNotice)
        XCTAssertNil(session.lastError)
        XCTAssertEqual(accessRecorder.stopped, [firstURL])
    }

    func testStaleEngineEventsCannotOverwriteReplacementMedia() async throws {
        let firstURL = URL(fileURLWithPath: "/tmp/first-generation.mkv")
        let secondURL = URL(fileURLWithPath: "/tmp/current-generation.mp4")
        let engine = FakePlayerEngine()
        let session = PlayerSession(engine: engine, bookmarkProvider: nil)

        try await session.open(firstURL)
        guard case let .load(firstRequest)? = engine.commands.first else {
            return XCTFail("Expected the first load request")
        }

        try await session.open(secondURL)
        guard case let .load(secondRequest)? = engine.commands.last else {
            return XCTFail("Expected the replacement load request")
        }

        engine.emit(.positionChanged(
            currentTime: 99,
            duration: 100,
            playbackID: firstRequest.playbackID
        ))
        engine.emit(.ended(playbackID: firstRequest.playbackID))
        engine.emit(.failed(
            PlaybackError(code: .corruptMedia, message: "Stale failure"),
            playbackID: firstRequest.playbackID
        ))
        engine.emit(.snapshot(
            PlayerSnapshot(
                phase: .ended,
                mediaURL: firstURL,
                currentTime: 100,
                duration: 100
            ),
            playbackID: firstRequest.playbackID
        ))

        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(session.currentMediaURL, secondURL)
        XCTAssertEqual(session.phase, .loading)
        XCTAssertEqual(session.snapshot.currentTime, 0)
        XCTAssertNil(session.lastError)

        engine.emit(.mediaLoaded(secondURL, playbackID: secondRequest.playbackID))
        engine.emit(.phaseChanged(.playing, playbackID: secondRequest.playbackID))
        let consumedCurrentEvent = await eventually { session.phase == .playing }
        XCTAssertTrue(consumedCurrentEvent)
    }

    func testCloseInvalidatesAnOpenWaitingForHistory() async throws {
        let url = URL(fileURLWithPath: "/tmp/closing.mkv")
        let historyGate = URLSuspensionGate(suspending: [url])
        let history = InMemoryHistoryStore(
            entries: [PlaybackHistoryEntry(url: url, position: 90, duration: 400)],
            lookupGate: historyGate
        )
        let engine = FakePlayerEngine()
        let accessRecorder = ResourceAccessRecorder()
        let session = PlayerSession(
            engine: engine,
            historyStore: history,
            bookmarkProvider: nil,
            resourceAccessor: FakeResourceAccessor(recorder: accessRecorder)
        )

        let pendingOpen = Task { @MainActor in
            try await session.open(url)
        }
        await historyGate.waitUntilStarted(url)

        await session.closeMedia()
        await historyGate.resume(url)

        do {
            try await pendingOpen.value
            XCTFail("Closing should cancel the in-flight open")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertEqual(session.snapshot, .empty)
        XCTAssertNil(session.resumeNotice)
        XCTAssertNil(session.lastError)
        XCTAssertEqual(accessRecorder.stopped, [url])
    }

    func testScrubbingIsLocalAndResponsiveUntilCommit() async throws {
        let engine = FakePlayerEngine()
        let session = PlayerSession(engine: engine, bookmarkProvider: nil)
        let url = URL(fileURLWithPath: "/tmp/movie.mkv")
        try await session.open(url)
        engine.emit(
            .snapshot(
                PlayerSnapshot(
                    phase: .playing,
                    mediaURL: url,
                    currentTime: 20,
                    duration: 100,
                    isSeekable: true
                )
            )
        )
        let consumedSnapshot = await eventually { session.canSeek }
        XCTAssertTrue(consumedSnapshot)

        session.beginScrubbing()
        session.updateScrubPosition(250)
        XCTAssertEqual(session.displayedPosition, 100)
        XCTAssertTrue(session.isScrubbing)

        engine.emit(.positionChanged(currentTime: 30, duration: 100))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(session.displayedPosition, 100)

        try await session.commitScrubbing()
        XCTAssertFalse(session.isScrubbing)
        XCTAssertEqual(session.snapshot.currentTime, 100)
        XCTAssertEqual(engine.commands.last, .seekTo(100))
    }

    func testSavesEveryFiveSecondsAndWhenPaused() async throws {
        let engine = FakePlayerEngine()
        let clock = TestDateClock()
        let history = InMemoryHistoryStore()
        let url = URL(fileURLWithPath: "/tmp/movie.mkv")
        let session = PlayerSession(
            engine: engine,
            historyStore: history,
            bookmarkProvider: FakeBookmarkProvider(data: Data([8, 8])),
            configuration: .init(progressSaveInterval: 5),
            now: clock.now
        )
        try await session.open(url)
        engine.emit(.phaseChanged(.playing))
        engine.emit(.positionChanged(currentTime: 10, duration: 100))
        let consumedInitialPosition = await eventually { session.snapshot.currentTime == 10 }
        XCTAssertTrue(consumedInitialPosition)
        let initialUpsertCount = await history.numberOfUpserts()
        XCTAssertEqual(initialUpsertCount, 0)

        clock.advance(by: 4.9)
        engine.emit(.positionChanged(currentTime: 15, duration: 100))
        try await Task.sleep(for: .milliseconds(20))
        let earlyUpsertCount = await history.numberOfUpserts()
        XCTAssertEqual(earlyUpsertCount, 0)

        clock.advance(by: 0.1)
        engine.emit(.positionChanged(currentTime: 16, duration: 100))
        let didAutosave = await eventuallyAsync {
            await history.numberOfUpserts() == 1
        }
        XCTAssertTrue(didAutosave)
        let autosaveUpsertCount = await history.numberOfUpserts()
        XCTAssertEqual(autosaveUpsertCount, 1)

        try await session.pause()
        let pausedUpsertCount = await history.numberOfUpserts()
        XCTAssertEqual(pausedUpsertCount, 2)
        let saved = await history.entry(for: MediaKey.make(for: url))
        XCTAssertEqual(saved?.position, 16)
        XCTAssertEqual(saved?.bookmarkData, Data([8, 8]))
    }

    func testReplacingMediaSavesAndBalancesSecurityScope() async throws {
        let engine = FakePlayerEngine()
        let history = InMemoryHistoryStore()
        let recorder = ResourceAccessRecorder()
        let session = PlayerSession(
            engine: engine,
            historyStore: history,
            bookmarkProvider: nil,
            resourceAccessor: FakeResourceAccessor(recorder: recorder)
        )
        let firstURL = URL(fileURLWithPath: "/tmp/first.mkv")
        let secondURL = URL(fileURLWithPath: "/tmp/second.mp4")

        try await session.open(firstURL)
        engine.emit(.snapshot(PlayerSnapshot(
            phase: .playing,
            mediaURL: firstURL,
            currentTime: 50,
            duration: 200,
            isSeekable: true
        )))
        let consumedProgress = await eventually { session.snapshot.currentTime == 50 }
        XCTAssertTrue(consumedProgress)
        try await session.open(secondURL)

        XCTAssertEqual(recorder.started, [firstURL, secondURL])
        XCTAssertEqual(recorder.stopped, [firstURL])
        let firstEntry = await history.entry(for: MediaKey.make(for: firstURL))
        XCTAssertEqual(firstEntry?.position, 50)

        await session.closeMedia()
        XCTAssertEqual(recorder.stopped, [firstURL, secondURL])
        XCTAssertEqual(session.snapshot, .empty)
    }

    func testCloseRetainsSecurityScopeUntilEngineFinishesStopping() async throws {
        let stopGate = OperationSuspensionGate()
        let engine = FakePlayerEngine(stopGate: stopGate)
        let recorder = ResourceAccessRecorder()
        let session = PlayerSession(
            engine: engine,
            bookmarkProvider: nil,
            resourceAccessor: FakeResourceAccessor(recorder: recorder)
        )
        let url = URL(fileURLWithPath: "/tmp/slow-stop.mkv")
        try await session.open(url)

        let closing = Task { @MainActor in
            await session.closeMedia()
        }
        await stopGate.waitUntilStarted()
        XCTAssertEqual(recorder.stopped, [])

        await stopGate.resume()
        await closing.value
        XCTAssertEqual(recorder.stopped, [url])
        XCTAssertEqual(session.snapshot, .empty)
    }

    func testCloseFailureDoesNotReleaseResourceBeforeConfirmedStop() async throws {
        let engine = FakePlayerEngine()
        let recorder = ResourceAccessRecorder()
        let session = PlayerSession(
            engine: engine,
            bookmarkProvider: nil,
            resourceAccessor: FakeResourceAccessor(recorder: recorder)
        )
        let url = URL(fileURLWithPath: "/tmp/stop-failure.mkv")
        try await session.open(url)
        let expected = PlaybackError(
            code: .commandFailed,
            message: "libmpv did not stop."
        )
        engine.failNextCommand(with: expected)

        await session.closeMedia()

        XCTAssertEqual(recorder.stopped, [])
        XCTAssertEqual(session.phase, .failed)
        XCTAssertEqual(session.lastError, expected)
    }

    func testExternalSubtitleScopeLivesUntilMediaCloses() async throws {
        let engine = FakePlayerEngine()
        let recorder = ResourceAccessRecorder()
        let session = PlayerSession(
            engine: engine,
            bookmarkProvider: nil,
            resourceAccessor: FakeResourceAccessor(recorder: recorder)
        )
        let videoURL = URL(fileURLWithPath: "/tmp/video.mkv")
        let subtitleURL = URL(fileURLWithPath: "/tmp/video.srt")
        try await session.open(videoURL)

        try await session.addExternalSubtitle(subtitleURL)
        XCTAssertEqual(recorder.started, [videoURL, subtitleURL])
        XCTAssertEqual(recorder.stopped, [])

        await session.closeMedia()
        XCTAssertEqual(Set(recorder.stopped), Set([videoURL, subtitleURL]))
    }

    func testEngineFailureBecomesRecoverableSessionError() async throws {
        let engine = FakePlayerEngine()
        let session = PlayerSession(engine: engine, bookmarkProvider: nil)
        let url = URL(fileURLWithPath: "/tmp/broken.mkv")
        let expected = PlaybackError(code: .corruptMedia, message: "Invalid EBML")
        engine.failNextCommand(with: expected)

        do {
            try await session.open(url)
            XCTFail("Expected open failure")
        } catch let error as PlaybackError {
            XCTAssertEqual(error, expected)
        }

        XCTAssertEqual(session.phase, .failed)
        XCTAssertEqual(session.lastError, expected)
    }

    func testAsynchronousFailureReleasesCurrentSecurityScopes() async throws {
        let engine = FakePlayerEngine()
        let recorder = ResourceAccessRecorder()
        let session = PlayerSession(
            engine: engine,
            bookmarkProvider: nil,
            resourceAccessor: FakeResourceAccessor(recorder: recorder)
        )
        let url = URL(fileURLWithPath: "/tmp/asynchronously-broken.mkv")
        try await session.open(url)

        engine.emit(.failed(PlaybackError(
            code: .corruptMedia,
            message: "The video is damaged."
        )))
        let consumedFailure = await eventually { session.phase == .failed }

        XCTAssertTrue(consumedFailure)
        XCTAssertEqual(recorder.stopped, [url])
    }

    func testBufferingGeometryAndScalingEventsUpdateSnapshot() async throws {
        let engine = FakePlayerEngine()
        let session = PlayerSession(engine: engine, bookmarkProvider: nil)
        let size = try XCTUnwrap(VideoDimensions(width: 3_840, height: 2_160))
        try await session.open(URL(fileURLWithPath: "/tmp/geometry.mkv"))

        engine.emit(.bufferingChanged(true))
        engine.emit(.videoSizeChanged(size))
        engine.emit(.videoScalingChanged(.fill))
        let consumedVideoState = await eventually {
            session.snapshot.isBuffering
                && session.snapshot.naturalVideoSize == size
                && session.snapshot.videoScaling == .fill
        }
        XCTAssertTrue(consumedVideoState)

        try await session.setVideoScaling(.actualSize)
        XCTAssertEqual(session.snapshot.videoScaling, .actualSize)
        XCTAssertEqual(engine.commands.last, .videoScaling(.actualSize))
    }

    func testEndedEventPersistsCompletedState() async throws {
        let engine = FakePlayerEngine()
        let history = InMemoryHistoryStore()
        let url = URL(fileURLWithPath: "/tmp/movie.mkv")
        let session = PlayerSession(
            engine: engine,
            historyStore: history,
            bookmarkProvider: nil
        )
        try await session.open(url)
        engine.emit(.positionChanged(currentTime: 95, duration: 100))
        engine.emit(.ended)
        let consumedEnd = await eventually { session.phase == .ended }
        XCTAssertTrue(consumedEnd)

        // libmpv can publish one last decoded position after eof-reached.
        // Completed history must remain pinned to the duration.
        engine.emit(.positionChanged(currentTime: 97, duration: 100))
        try await Task.sleep(for: .milliseconds(20))
        await session.saveProgress()

        let entry = await history.entry(for: MediaKey.make(for: url))
        XCTAssertEqual(entry?.position, 100)
        XCTAssertEqual(entry?.isCompleted, true)
    }
}
