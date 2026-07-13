import Testing
import Foundation
import PlayerCore
@testable import MPVKit

@Suite("libmpv fallback")
struct MPVFallbackTests {
    @Test("Local playback uses only supported deterministic engine options")
    func deterministicLocalOptions() {
        let options = Dictionary(
            uniqueKeysWithValues: MPVConfiguration.localPlaybackOptions.map { ($0.name, $0.value) }
        )

        for option in [
            "config", "input-default-bindings", "terminal", "access-references",
            "autoload-files",
        ] {
            #expect(options[option] == "no")
        }

        #expect(options["idle"] == "yes")
        #expect(options["keep-open"] == "yes")
        #expect(options["vo"] == "libmpv")
        #expect(options["hwdec"] == "auto-safe")

        // MediaCore is compiled without cplayer, Lua, or JavaScript. These
        // front-end/script options therefore do not exist in the bundled
        // libmpv and would make initialization fail with MPV_ERROR_OPTION_NOT_FOUND.
        for unavailableOption in [
            "load-scripts", "load-auto-profiles", "load-commands", "load-console",
            "load-context-menu", "load-positioning", "load-select",
            "load-stats-overlay", "osc", "ytdl",
        ] {
            #expect(options[unavailableOption] == nil)
        }
    }

    @Test("Initial properties cannot skip loading and EOF remains ended")
    func playbackPhaseOrdering() async {
        let stream = AsyncStream<PlayerEvent>.makeStream(bufferingPolicy: .unbounded)
        let sink = MPVEventSink(continuation: stream.continuation)
        let url = URL(fileURLWithPath: "/tmp/fixture.mkv")
        let playbackID = UUID()

        sink.beginLoading(
            MediaLoadRequest(playbackID: playbackID, url: url, autoplay: true)
        )
        sink.setPhase(.playing)
        sink.fileDidStart(entryID: 7, path: url.path)
        sink.mediaLoaded(entryID: 7, path: url.path, isPaused: false)
        sink.ended(entryID: 7)
        sink.setPhase(.paused)
        sink.finish()

        var events: [PlayerEvent] = []
        for await event in stream.stream {
            events.append(event)
        }
        let phases = events.compactMap { event -> PlaybackPhase? in
            guard case let .phaseChanged(phase) = event.payload else { return nil }
            return phase
        }

        #expect(phases == [.loading, .playing])
        #expect(events.contains(.ended(playbackID: playbackID)))
        #expect(
            events.last
                == .snapshot(
                    PlayerSnapshot(phase: .ended, mediaURL: url),
                    playbackID: playbackID
                )
        )
    }

    @Test("Rapid replacement never labels an older file as the newest request")
    func rapidReplacementCorrelation() async throws {
        let stream = AsyncStream<PlayerEvent>.makeStream(bufferingPolicy: .unbounded)
        let sink = MPVEventSink(continuation: stream.continuation)
        let bURL = URL(fileURLWithPath: "/tmp/B.mkv")
        let cURL = URL(fileURLWithPath: "/tmp/C.mp4")
        let bID = UUID()
        let cID = UUID()

        sink.beginLoading(MediaLoadRequest(playbackID: bID, url: bURL))
        sink.beginLoading(MediaLoadRequest(playbackID: cID, url: cURL))

        // These are B's already queued events. They must remain tagged B and
        // must not reset or complete the newer C request.
        sink.fileDidStart(entryID: 20, path: bURL.path)
        sink.mediaLoaded(entryID: 20, path: bURL.path, isPaused: false)
        sink.stopped(entryID: 20)

        sink.fileDidStart(entryID: 21, path: cURL.path)
        sink.mediaLoaded(entryID: 21, path: cURL.path, isPaused: false)
        try await sink.waitUntilLoaded(playbackID: cID)
        sink.finish()

        var events: [PlayerEvent] = []
        for await event in stream.stream {
            events.append(event)
        }

        let loaded = events.compactMap { event -> (UUID?, URL)? in
            guard case let .mediaLoaded(url) = event.payload else { return nil }
            return (event.playbackID, url)
        }
        #expect(loaded.count == 1)
        #expect(loaded.first?.0 == cID)
        #expect(loaded.first?.1 == cURL)
        #expect(!events.contains { event in
            event.playbackID == cID && event.payload == .mediaLoaded(bURL)
        })
        #expect(events.last == .snapshot(
            PlayerSnapshot(phase: .playing, mediaURL: cURL),
            playbackID: cID
        ))
    }

    @Test("A START path must match a pending local request")
    func startPathVerification() async throws {
        let stream = AsyncStream<PlayerEvent>.makeStream(bufferingPolicy: .unbounded)
        let sink = MPVEventSink(continuation: stream.continuation)
        let wantedURL = URL(fileURLWithPath: "/tmp/wanted.mkv")
        let wrongURL = URL(fileURLWithPath: "/tmp/wrong.mkv")
        let playbackID = UUID()

        sink.beginLoading(MediaLoadRequest(playbackID: playbackID, url: wantedURL))
        sink.fileDidStart(entryID: 30, path: wrongURL.path)
        sink.mediaLoaded(entryID: 30, path: wrongURL.path, isPaused: false)
        sink.fileDidStart(entryID: 31, path: "/tmp/folder/../wanted.mkv")
        sink.mediaLoaded(
            entryID: 31,
            path: "/tmp/folder/../wanted.mkv",
            isPaused: false
        )
        try await sink.waitUntilLoaded(playbackID: playbackID)
        sink.finish()

        var loadedURLs: [URL] = []
        for await event in stream.stream {
            if case let .mediaLoaded(url) = event.payload {
                loadedURLs.append(url)
            }
        }
        #expect(loadedURLs == [wantedURL])
    }

    @Test("Stop completes only when the active entry ends")
    func stopLifecycle() async throws {
        let stream = AsyncStream<PlayerEvent>.makeStream(bufferingPolicy: .unbounded)
        let sink = MPVEventSink(continuation: stream.continuation)
        let url = URL(fileURLWithPath: "/tmp/stopping.mkv")
        let playbackID = UUID()

        sink.beginLoading(MediaLoadRequest(playbackID: playbackID, url: url))
        sink.fileDidStart(entryID: 40, path: url.path)
        sink.mediaLoaded(entryID: 40, path: url.path, isPaused: false)
        try await sink.waitUntilLoaded(playbackID: playbackID)
        let stopToken = sink.prepareToStop()
        sink.stopped(entryID: 40)
        try await sink.waitUntilStopped(stopToken)
        sink.finish()

        var events: [PlayerEvent] = []
        for await event in stream.stream { events.append(event) }
        #expect(events.contains(.phaseChanged(.idle, playbackID: playbackID)))
    }

    @Test("A failed stop never fabricates an idle transition")
    func failedStopPreservesActiveMedia() async throws {
        let stream = AsyncStream<PlayerEvent>.makeStream(bufferingPolicy: .unbounded)
        let sink = MPVEventSink(continuation: stream.continuation)
        let url = URL(fileURLWithPath: "/tmp/still-active.mkv")
        let playbackID = UUID()

        sink.beginLoading(MediaLoadRequest(playbackID: playbackID, url: url))
        sink.fileDidStart(entryID: 50, path: url.path)
        sink.mediaLoaded(entryID: 50, path: url.path, isPaused: false)
        try await sink.waitUntilLoaded(playbackID: playbackID)

        let stopToken = sink.prepareToStop()
        sink.abandonStop(stopToken)
        #expect(sink.requiresStop)
        sink.finish()

        var events: [PlayerEvent] = []
        for await event in stream.stream { events.append(event) }
        #expect(!events.contains(.phaseChanged(.idle, playbackID: playbackID)))
    }

    @Test("Event sink shutdown fails waiters that register afterward")
    func eventSinkTerminalFailure() async {
        let stream = AsyncStream<PlayerEvent>.makeStream(bufferingPolicy: .unbounded)
        let sink = MPVEventSink(continuation: stream.continuation)
        let expected = PlaybackError(
            code: .engineUnavailable,
            message: "Event pump stopped"
        )
        sink.shutdown(with: expected)

        do {
            try await sink.waitUntilLoaded(playbackID: UUID())
            Issue.record("Expected terminal event-sink failure")
        } catch let error as PlaybackError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        sink.finish()
    }

    @Test("libmpv loading errors distinguish corrupt from unsupported media")
    func endFileErrorMapping() {
        #expect(MPVEventPump.playbackErrorCode(forMPVError: -17) == .unsupportedMedia)
        #expect(MPVEventPump.playbackErrorCode(forMPVError: -18) == .unsupportedMedia)
        #expect(MPVEventPump.playbackErrorCode(forMPVError: -13) == .corruptMedia)
        #expect(MPVEventPump.playbackErrorCode(forMPVError: -16) == .corruptMedia)
        #expect(MPVEventPump.playbackErrorCode(forMPVError: -20) == .corruptMedia)
        #expect(MPVEventPump.playbackErrorCode(forMPVError: -12) == .unknown)
    }

    @Test("Command replies are retained when they beat waiter registration")
    func commandReplyRace() async throws {
        let broker = MPVAsyncCommandBroker()
        broker.resolve(replyID: 41, result: .success(()))
        try await broker.waitForReply(41)

        let expected = PlaybackError(code: .commandFailed, message: "Rejected")
        broker.resolve(replyID: 42, result: .failure(expected))
        do {
            try await broker.waitForReply(42)
            Issue.record("Expected the command reply to throw")
        } catch let error as PlaybackError {
            #expect(error == expected)
        }
    }

    @Test("Broker shutdown also fails commands that register afterward")
    func commandBrokerTerminalFailure() async {
        let broker = MPVAsyncCommandBroker()
        let expected = PlaybackError(
            code: .engineUnavailable,
            message: "Engine stopped"
        )
        broker.failAll(with: expected)

        do {
            try await broker.waitForReply(99)
            Issue.record("Expected terminal broker failure")
        } catch let error as PlaybackError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Disabled loading has a deterministic unavailable state")
    func disabledState() {
        let client = MPVClient(librarySearch: .disabled(reason: "test fixture"))

        #expect(
            client.availability
                == .unavailable(.disabled("test fixture"))
        )
        #expect(client.availability.isAvailable == false)
        #expect(client.availability.error == .disabled("test fixture"))
        #expect(
            client.send(.stop)
                == .unavailable(.disabled("test fixture"))
        )
    }

    @Test("An explicit missing dylib does not crash or use system fallbacks")
    func missingExplicitPath() {
        let path = "/definitely/not/present/libmpv-test.dylib"
        let client = MPVClient(librarySearch: .paths([path]))

        #expect(
            client.availability
                == .unavailable(.libraryNotFound(searched: [path]))
        )
    }

    @Test("Unavailable client still validates commands deterministically")
    func validationBeforeAvailability() {
        let client = MPVClient(librarySearch: .disabled(reason: "test fixture"))
        #expect(
            client.send(.setVolume(2))
                == .invalidCommand(.volumeOutOfRange)
        )
    }

    @Test("PlayerEngine adapter exposes and throws the same fallback")
    func engineFallback() async {
        let engine = MPVEngine(librarySearch: .disabled(reason: "test fixture"))

        #expect(engine.isAvailable == false)
        #expect(engine.availabilityError == .disabled("test fixture"))

        await #expect(throws: PlaybackError.self) {
            try await engine.play()
        }

        // Availability is reported when a command is attempted. Merely opening
        // the app remains a normal empty player state.
    }

    @Test("Fallback video surface is safe to construct")
    @MainActor
    func fallbackSurface() {
        let engine = MPVEngine(librarySearch: .disabled(reason: "test fixture"))
        let surface = MPVVideoSurface(engine: engine)

        #expect(
            surface.state
                == .unavailable(.disabled("test fixture"))
        )
    }
}
