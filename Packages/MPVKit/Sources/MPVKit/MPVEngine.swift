import Foundation
import PlayerCore

/// PlayerCore's libmpv-backed implementation.
///
/// The actor serializes user commands without using the main actor. libmpv's
/// event pump owns its own queue and sends value-type events through
/// `AsyncStream`, keeping all C callbacks away from AppKit and SwiftUI state.
public actor MPVEngine: PlayerEngine {
    public nonisolated let events: AsyncStream<PlayerEvent>
    internal nonisolated let client: MPVClient

    private nonisolated let eventSink: MPVEventSink
    private nonisolated let eventPump: MPVEventPump
    private nonisolated let commandBroker: MPVAsyncCommandBroker
    private var loadGeneration: UInt64 = 0

    public nonisolated var isAvailable: Bool {
        client.availability.isAvailable
    }

    public nonisolated var availabilityError: MPVUnavailableReason? {
        client.availability.error
    }

    public init(
        configuration: MPVConfiguration = MPVConfiguration(),
        librarySearch: MPVLibrarySearch = .bundledAndSystem
    ) {
        let client = MPVClient(
            configuration: configuration,
            librarySearch: librarySearch
        )
        let stream = AsyncStream<PlayerEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(128)
        )
        let sink = MPVEventSink(continuation: stream.continuation)
        let commandBroker = MPVAsyncCommandBroker()
        let pump = MPVEventPump(
            client: client,
            sink: sink,
            commandBroker: commandBroker
        )

        self.client = client
        events = stream.stream
        eventSink = sink
        eventPump = pump
        self.commandBroker = commandBroker

        if client.availability.isAvailable {
            client.startObservingProperties()
            pump.start()
        }
    }

    deinit {
        eventPump.stop()
        commandBroker.failAll(
            with: PlaybackError(
                code: .engineUnavailable,
                message: "The playback engine was released."
            )
        )
        eventSink.finish()
    }

    public func load(_ request: MediaLoadRequest) async throws {
        loadGeneration &+= 1
        let generation = loadGeneration
        try ensureAvailable()
        guard request.url.isFileURL else {
            throw PlaybackError(
                code: .unsupportedMedia,
                message: "Only local media files are supported.",
                recoverySuggestion: "Choose a video stored on this Mac."
            )
        }
        guard FileManager.default.fileExists(atPath: request.url.path) else {
            throw PlaybackError(
                code: .fileNotFound,
                message: "The video could not be found.",
                diagnostics: request.url.path,
                recoverySuggestion: "Choose the file again."
            )
        }
        guard FileManager.default.isReadableFile(atPath: request.url.path) else {
            throw PlaybackError(
                code: .accessDenied,
                message: "The video could not be read.",
                diagnostics: request.url.path,
                recoverySuggestion: "Choose the file again to grant access."
            )
        }
        let renderContextIsReady = await client.waitForRenderContext()
        guard generation == loadGeneration else {
            throw PlaybackError(
                code: .cancelled,
                message: "A newer video replaced this request."
            )
        }
        guard renderContextIsReady else {
            throw PlaybackError(
                code: .renderingFailed,
                message: "The video surface is not ready.",
                diagnostics: "libmpv requires its OpenGL render context before playback starts.",
                recoverySuggestion: "Close and reopen the player window, then try again."
            )
        }

        if eventSink.requiresStop {
            try await stopForReplacement()
            guard generation == loadGeneration else {
                throw PlaybackError(
                    code: .cancelled,
                    message: "A newer video replaced this request."
                )
            }
        }

        // Pause is set before loading so autoplay is deterministic and never
        // leaks a few frames/audio samples from the previous session.
        try await submit(.setPaused(!request.autoplay))
        guard generation == loadGeneration else {
            throw PlaybackError(
                code: .cancelled,
                message: "A newer video replaced this request."
            )
        }
        eventSink.beginLoading(request)
        do {
            try await submit(
                .loadFile(
                    request.url,
                    startPosition: request.startPosition
                )
            )
            guard generation == loadGeneration else {
                throw PlaybackError(
                    code: .cancelled,
                    message: "A newer video replaced this request."
                )
            }
            try await eventSink.waitUntilLoaded(playbackID: request.playbackID)
            guard generation == loadGeneration else {
                throw PlaybackError(
                    code: .cancelled,
                    message: "A newer video replaced this request."
                )
            }
        } catch {
            let playbackError = PlaybackError.wrapping(
                error,
                fallbackCode: .commandFailed,
                recoverySuggestion: "Choose another video."
            )
            eventSink.failLoad(playbackID: request.playbackID, error: playbackError)
            throw playbackError
        }
    }

    public func play() async throws {
        try await submit(.setPaused(false))
    }

    public func pause() async throws {
        try await submit(.setPaused(true))
    }

    public func seek(to seconds: TimeInterval) async throws {
        try await submit(.seekAbsolute(seconds))
    }

    public func seek(by seconds: TimeInterval) async throws {
        try await submit(.seekRelative(seconds))
    }

    public func setVolume(_ normalizedVolume: Double) async throws {
        try await submit(.setVolume(normalizedVolume))
    }

    public func setMuted(_ muted: Bool) async throws {
        try await submit(.setMuted(muted))
    }

    public func setRate(_ rate: Double) async throws {
        try await submit(.setRate(rate))
    }

    public func setVideoScaling(_ mode: VideoScalingMode) async throws {
        switch mode {
        case .fit:
            try await submit(.setVideoUnscaled(false))
            try await submit(.setPanscan(0))
        case .fill:
            try await submit(.setVideoUnscaled(false))
            try await submit(.setPanscan(1))
        case .actualSize:
            try await submit(.setPanscan(0))
            try await submit(.setVideoUnscaled(true))
        }
        eventSink.setVideoScaling(mode)
    }

    public func selectTrack(id: Int64?, kind: TrackKind) async throws {
        let type: MPVTrackType = switch kind {
        case .video: .video
        case .audio: .audio
        case .subtitle: .subtitle
        }
        try await submit(.selectTrack(id: id, type: type))
    }

    public func selectChapter(index: Int) async throws {
        try await submit(.selectChapter(index))
    }

    public func addExternalSubtitle(_ url: URL) async throws {
        guard url.isFileURL else {
            throw PlaybackError(
                code: .unsupportedMedia,
                message: "Only local subtitle files are supported."
            )
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PlaybackError(
                code: .fileNotFound,
                message: "The subtitle file could not be found.",
                diagnostics: url.path
            )
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw PlaybackError(
                code: .accessDenied,
                message: "The subtitle file could not be read.",
                diagnostics: url.path
            )
        }
        try await submit(.addSubtitle(url))
    }

    public func stop() async throws {
        loadGeneration &+= 1
        try await stopForReplacement()
    }

    private func ensureAvailable() throws {
        guard let reason = availabilityError else {
            return
        }
        throw Self.playbackError(for: reason)
    }

    private func stopForReplacement() async throws {
        guard eventSink.requiresStop else {
            return
        }
        let token = eventSink.prepareToStop()
        do {
            try await submit(.stop)
            try await eventSink.waitUntilStopped(token)
        } catch {
            // A failed command or interrupted wait is not evidence that libmpv
            // released the file. Preserve the media state so PlayerSession
            // keeps its security-scoped access alive and can retry the stop.
            eventSink.abandonStop(token)
            throw error
        }
    }

    private func submit(_ command: MPVCommand) async throws {
        try ensureAvailable()
        switch client.send(command) {
        case let .accepted(replyID):
            try await commandBroker.waitForReply(replyID)
        case let .invalidCommand(mappingError):
            throw PlaybackError(
                code: .commandFailed,
                message: "The playback command was not valid.",
                diagnostics: String(describing: mappingError)
            )
        case let .unavailable(reason):
            throw Self.playbackError(for: reason)
        case let .rejected(code, message):
            throw PlaybackError(
                code: .commandFailed,
                message: message,
                diagnostics: "libmpv error \(code)"
            )
        }
    }

    private nonisolated static func playbackError(
        for reason: MPVUnavailableReason
    ) -> PlaybackError {
        PlaybackError(
            code: .engineUnavailable,
            message: "The playback engine is unavailable.",
            diagnostics: String(describing: reason),
            recoverySuggestion: "Reinstall the app or use a complete release build."
        )
    }
}
