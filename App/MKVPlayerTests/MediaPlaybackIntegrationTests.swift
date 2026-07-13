import AppKit
import Foundation
import MPVKit
import PlayerCore
import XCTest

/// Exercises the real dynamically loaded libmpv engine and its AppKit render
/// surface. Developer/PR builds without MediaCore (and without a development
/// libmpv override) skip these tests; release CI embeds the pinned MediaCore and
/// must execute them.
@MainActor
final class MediaPlaybackIntegrationTests: XCTestCase {
    // The production app creates one CAOpenGLLayer-backed video surface for the
    // lifetime of its one player window. Keeping that same invariant here also
    // avoids exercising unsupported rapid NSWindow/OpenGL teardown between
    // XCTest methods.
    private static var sharedHarness: PlaybackHarness?

    func testMKVLoadsTracksChaptersAndExternalSubtitle() async throws {
        let harness = try await makeHarness()
        let engine = harness.engine
        let probe = harness.probe

        let mediaURL = try fixtureURL("tracks-chapters-subtitles.mkv")
        let playbackID = UUID()
        try await withTimeout {
            try await engine.load(
                MediaLoadRequest(
                    playbackID: playbackID,
                    url: mediaURL,
                    autoplay: false
                )
            )
        }

        let loaded = try await waitForSnapshot(
            in: probe,
            playbackID: playbackID
        ) { snapshot in
            snapshot.mediaURL == mediaURL
                && snapshot.tracks.filter { $0.kind == .audio }.count == 2
                && snapshot.tracks.filter { $0.kind == .subtitle }.count == 2
                && snapshot.chapters.count == 2
        }

        XCTAssertEqual(loaded.phase, .paused)
        XCTAssertEqual(
            loaded.tracks.filter { $0.kind == .audio }.compactMap(\.title),
            ["Main Audio", "Alternate Audio"]
        )
        XCTAssertEqual(
            loaded.tracks.filter { $0.kind == .subtitle }.compactMap(\.title),
            ["English SRT", "Styled ASS"]
        )
        XCTAssertEqual(loaded.chapters.map(\.title), ["Opening", "Second Act"])
        XCTAssertEqual(loaded.chapters.map(\.startTime), [0, 1.2])

        let externalSubtitle = try fixtureURL("external.srt")
        try await withTimeout {
            try await engine.addExternalSubtitle(externalSubtitle)
        }
        let withExternalSubtitle = try await waitForSnapshot(
            in: probe,
            playbackID: playbackID
        ) { snapshot in
            snapshot.tracks.contains { track in
                track.kind == .subtitle && track.isExternal
            }
        }
        XCTAssertEqual(
            withExternalSubtitle.tracks.filter {
                $0.kind == .subtitle && $0.isExternal
            }.count,
            1
        )

        try await withTimeout {
            try await engine.stop()
        }
    }

    func testMP4LoadsAndRapidReplacementKeepsNewestIdentity() async throws {
        let harness = try await makeHarness()
        let engine = harness.engine
        let probe = harness.probe

        let firstURL = try fixtureURL("tracks-chapters-subtitles.mkv")
        let finalURL = try fixtureURL("h264-aac.mp4")
        let firstID = UUID()
        let finalID = UUID()

        let firstLoad = Task {
            try await engine.load(
                MediaLoadRequest(
                    playbackID: firstID,
                    url: firstURL,
                    autoplay: false
                )
            )
        }
        await Task.yield()

        try await withTimeout {
            try await engine.load(
                MediaLoadRequest(
                    playbackID: finalID,
                    url: finalURL,
                    autoplay: false
                )
            )
        }
        firstLoad.cancel()
        _ = try? await withTimeout {
            try await firstLoad.value
        }

        let finalSnapshot = try await waitForSnapshot(
            in: probe,
            playbackID: finalID
        ) { snapshot in
            snapshot.mediaURL == finalURL
                && snapshot.tracks.contains { $0.kind == .video }
                && snapshot.tracks.contains { $0.kind == .audio }
                && snapshot.isSeekable
                && (snapshot.duration ?? 0) > 2
        }

        XCTAssertEqual(finalSnapshot.phase, .paused)
        XCTAssertEqual(finalSnapshot.mediaURL, finalURL)
        XCTAssertTrue(finalSnapshot.isSeekable)
        XCTAssertGreaterThan(finalSnapshot.duration ?? 0, 2)
        let events = await probe.allEvents()
        XCTAssertFalse(events.contains { event in
            guard event.playbackID == finalID,
                  case let .mediaLoaded(url) = event.payload
            else {
                return false
            }
            return url != finalURL
        })

        try await withTimeout {
            try await engine.stop()
        }
    }

    func testMalformedMKVReportsUnsupportedContainer() async throws {
        let harness = try await makeHarness()
        let engine = harness.engine

        let malformedURL = try fixtureURL("malformed.mkv")
        do {
            try await withTimeout {
                try await engine.load(
                    MediaLoadRequest(url: malformedURL, autoplay: false)
                )
            }
            XCTFail("Malformed media unexpectedly loaded")
        } catch let error as PlaybackError {
            XCTAssertEqual(error.code, .unsupportedMedia)
            XCTAssertFalse(error.message.isEmpty)
            XCTAssertNotNil(error.diagnostics)
        }

        try await withTimeout {
            try await engine.stop()
        }
    }

    func testRecognizedButTruncatedMKVReachesControlledTerminalState() async throws {
        let harness = try await makeHarness()
        let engine = harness.engine
        let probe = harness.probe

        let truncatedURL = try fixtureURL("truncated.mkv")
        let playbackID = UUID()
        var didLoad = false
        do {
            try await withTimeout {
                try await engine.load(
                    MediaLoadRequest(
                        playbackID: playbackID,
                        url: truncatedURL,
                        autoplay: true
                    )
                )
            }
            didLoad = true
        } catch let error as PlaybackError {
            XCTAssertTrue(
                [.corruptMedia, .unsupportedMedia].contains(error.code),
                "Unexpected controlled error: \(error)"
            )
            XCTAssertFalse(error.message.isEmpty)
        }

        if didLoad {
            let terminal = try await waitForSnapshot(
                in: probe,
                playbackID: playbackID
            ) { snapshot in
                snapshot.phase == .ended || snapshot.phase == .failed
            }
            XCTAssertTrue(terminal.phase == .ended || terminal.phase == .failed)
        }

        try await withTimeout {
            try await engine.stop()
        }
    }

    private func makeHarness() async throws -> PlaybackHarness {
        if let sharedHarness = Self.sharedHarness {
            return sharedHarness
        }

        let engine = await Task.detached(priority: .userInitiated) {
            MPVEngine()
        }.value
        guard engine.isAvailable else {
            let diagnostics = String(describing: engine.availabilityError)
#if MKVPLAYER_REQUIRE_MEDIA_CORE_TESTS
            throw IntegrationTestFailure.requiredEngineUnavailable(diagnostics)
#else
            throw XCTSkip(
                "Real playback requires the pinned MediaCore or a development libmpv: "
                    + diagnostics
            )
#endif
        }

        let surface = MPVVideoSurface(engine: engine)
        guard surface.state == .ready else {
            XCTFail("libmpv loaded but its video surface was unavailable: \(surface.state)")
            throw IntegrationTestFailure.renderSurfaceUnavailable
        }

        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 480, height: 270),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Playback Integration Test"
        window.contentView = surface
        window.orderFront(nil)
        window.displayIfNeeded()
        surface.displayIfNeeded()

        // `load` itself verifies that CAOpenGLLayer created the official libmpv
        // render context within two seconds. A loaded engine with a broken
        // render surface is a test failure, never an availability skip.
        let harness = PlaybackHarness(
            engine: engine,
            window: window,
            probe: PlaybackEventProbe(events: engine.events)
        )
        Self.sharedHarness = harness
        return harness
    }

    private func fixtureURL(_ name: String) throws -> URL {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repositoryRoot
            .appendingPathComponent("Tests/Fixtures/Generated", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("Required committed fixture is missing: \(url.path)")
            throw IntegrationTestFailure.missingFixture(url)
        }
        return url
    }

    private func waitForSnapshot(
        in probe: PlaybackEventProbe,
        playbackID: UUID,
        timeout: Duration = .seconds(8),
        matching predicate: (PlayerSnapshot) -> Bool
    ) async throws -> PlayerSnapshot {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while clock.now < deadline {
            if let snapshot = await probe.snapshot(playbackID: playbackID),
               predicate(snapshot) {
                return snapshot
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        throw IntegrationTestFailure.timedOut(
            "Waiting for playback snapshot \(playbackID)"
        )
    }
}

private struct PlaybackHarness {
    let engine: MPVEngine
    let window: NSWindow
    let probe: PlaybackEventProbe
}

private actor PlaybackEventStore {
    private var events: [PlayerEvent] = []
    private var snapshots: [UUID: PlayerSnapshot] = [:]

    func append(_ event: PlayerEvent) {
        events.append(event)
        guard let playbackID = event.playbackID else { return }

        var snapshot = snapshots[playbackID] ?? .empty
        switch event.payload {
        case let .snapshot(replacement):
            snapshot = replacement
        case let .phaseChanged(phase):
            snapshot.phase = phase
        case let .positionChanged(currentTime, duration):
            snapshot.currentTime = currentTime
            snapshot.duration = duration
        case let .bufferingChanged(buffering):
            snapshot.isBuffering = buffering
        case let .videoScalingChanged(scaling):
            snapshot.videoScaling = scaling
        case let .videoSizeChanged(size):
            snapshot.naturalVideoSize = size
        case let .volumeChanged(volume, isMuted):
            snapshot.volume = volume
            snapshot.isMuted = isMuted
        case let .rateChanged(rate):
            snapshot.rate = rate
        case let .tracksChanged(tracks):
            snapshot.tracks = tracks
        case let .chaptersChanged(chapters):
            snapshot.chapters = chapters
        case let .mediaLoaded(url):
            snapshot.mediaURL = url
        case .ended:
            snapshot.phase = .ended
        case .failed:
            snapshot.phase = .failed
        }
        snapshots[playbackID] = snapshot
    }

    func allEvents() -> [PlayerEvent] {
        events
    }

    func snapshot(playbackID: UUID) -> PlayerSnapshot? {
        snapshots[playbackID]
    }
}

private final class PlaybackEventProbe: @unchecked Sendable {
    private let store: PlaybackEventStore
    private let task: Task<Void, Never>

    init(events: AsyncStream<PlayerEvent>) {
        let store = PlaybackEventStore()
        self.store = store
        task = Task.detached {
            for await event in events {
                guard !Task.isCancelled else { break }
                await store.append(event)
            }
        }
    }

    deinit {
        task.cancel()
    }

    func allEvents() async -> [PlayerEvent] {
        await store.allEvents()
    }

    func snapshot(playbackID: UUID) async -> PlayerSnapshot? {
        await store.snapshot(playbackID: playbackID)
    }
}

private enum IntegrationTestFailure: Error, LocalizedError {
    case missingFixture(URL)
    case renderSurfaceUnavailable
    case requiredEngineUnavailable(String)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case let .missingFixture(url):
            "Required committed fixture is missing: \(url.path)"
        case .renderSurfaceUnavailable:
            "libmpv loaded, but its AppKit video surface was unavailable."
        case let .requiredEngineUnavailable(diagnostics):
            "Release integration tests require embedded MediaCore: \(diagnostics)"
        case let .timedOut(operation):
            "Integration test timed out: \(operation)"
        }
    }
}

private func withTimeout<T: Sendable>(
    _ timeout: Duration = .seconds(10),
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask(operation: operation)
        group.addTask {
            try await Task.sleep(for: timeout)
            throw IntegrationTestFailure.timedOut("libmpv operation")
        }

        guard let result = try await group.next() else {
            throw IntegrationTestFailure.timedOut("libmpv operation")
        }
        group.cancelAll()
        return result
    }
}
