import Combine
import Foundation

@MainActor
public final class PlayerSession: ObservableObject {
    public struct Configuration: Sendable, Equatable {
        public var positionPublishInterval: TimeInterval
        public var progressSaveInterval: TimeInterval
        public var resumePolicy: ResumePolicy

        public init(
            positionPublishInterval: TimeInterval = 0.25,
            progressSaveInterval: TimeInterval = 5,
            resumePolicy: ResumePolicy = ResumePolicy()
        ) {
            self.positionPublishInterval = max(0, positionPublishInterval)
            self.progressSaveInterval = max(0, progressSaveInterval)
            self.resumePolicy = resumePolicy
        }

        public static let `default` = Configuration()
    }

    @Published public private(set) var snapshot: PlayerSnapshot = .empty
    @Published public private(set) var scrubPosition: TimeInterval?
    @Published public private(set) var resumeNotice: ResumeNotice?
    @Published public private(set) var lastError: PlaybackError?
    @Published public private(set) var lastPersistenceError: String?

    public var phase: PlaybackPhase { snapshot.phase }
    public var currentMediaURL: URL? { snapshot.mediaURL }
    public var displayedPosition: TimeInterval { scrubPosition ?? snapshot.currentTime }
    public var isScrubbing: Bool { scrubPosition != nil }
    public var canSeek: Bool { snapshot.mediaURL != nil && snapshot.isSeekable }
    public var canPlayOrPause: Bool {
        switch phase {
        case .ready, .playing, .paused, .ended: true
        case .idle, .loading, .failed: false
        }
    }

    private let engine: any PlayerEngine
    private let historyStore: (any PlaybackHistoryStoring)?
    private let bookmarkProvider: (any BookmarkProviding)?
    private let resourceAccessor: any SecurityScopedResourceAccessing
    private let configuration: Configuration
    private let now: @Sendable () -> Date

    private var eventTask: Task<Void, Never>?
    private var mediaAccess: (any SecurityScopedResourceAccess)?
    private var subtitleAccesses: [any SecurityScopedResourceAccess] = []
    private var currentBookmarkData: Data?
    private var latestEnginePosition: TimeInterval = 0
    private var latestEngineDuration: TimeInterval?
    private var lastPositionPublishedAt: Date?
    private var lastProgressSavedAt: Date?
    private var activePlaybackID: UUID?
    /// Invalidates reentrant media lifecycle operations after any suspension point.
    private var mediaOperationGeneration: UInt64 = 0

    public init(
        engine: any PlayerEngine,
        historyStore: (any PlaybackHistoryStoring)? = nil,
        bookmarkProvider: (any BookmarkProviding)? = SecurityScopedBookmarkProvider(),
        resourceAccessor: any SecurityScopedResourceAccessing = SystemSecurityScopedResourceAccessor(),
        configuration: Configuration = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.engine = engine
        self.historyStore = historyStore
        self.bookmarkProvider = bookmarkProvider
        self.resourceAccessor = resourceAccessor
        self.configuration = configuration
        self.now = now

        let events = engine.events
        self.eventTask = Task { @MainActor [weak self, events] in
            for await event in events {
                guard !Task.isCancelled, let self else { return }
                await self.consume(event)
            }
        }
    }

    deinit {
        eventTask?.cancel()
        mediaAccess?.stop()
        subtitleAccesses.forEach { $0.stop() }
    }

    public func open(
        _ url: URL,
        autoplay: Bool = true,
        allowResume: Bool = true
    ) async throws {
        let generation = beginMediaOperation()
        await saveProgress(ifCurrentMediaOperationIs: generation)
        try requireCurrentMediaOperation(generation)

        if activePlaybackID != nil {
            do {
                try await engine.stop()
                try requireCurrentMediaOperation(generation)
            } catch {
                try requireCurrentMediaOperation(generation)
                let playbackError = PlaybackError.wrapping(
                    error,
                    fallbackCode: .commandFailed,
                    recoverySuggestion: "Close the file and try again."
                )
                lastError = playbackError
                snapshot.phase = .failed
                throw playbackError
            }
        }

        activePlaybackID = nil
        releaseSecurityScopedResources()
        resetTransientState()

        let playbackID = UUID()
        activePlaybackID = playbackID
        let access = resourceAccessor.beginAccessing(url)
        mediaAccess = access
        snapshot = PlayerSnapshot(phase: .loading, mediaURL: url)
        latestEnginePosition = 0
        latestEngineDuration = nil

        if let bookmarkProvider {
            do {
                currentBookmarkData = try bookmarkProvider.makeBookmark(for: url)
            } catch {
                currentBookmarkData = nil
                lastPersistenceError = error.localizedDescription
            }
        }

        var resumePosition: TimeInterval?
        if allowResume, let historyStore {
            do {
                if let entry = try await historyStore.entry(for: MediaKey.make(for: url)) {
                    try requireCurrentMediaOperation(generation)
                    resumePosition = configuration.resumePolicy.resumePosition(for: entry)
                }
            } catch {
                try requireCurrentMediaOperation(generation)
                lastPersistenceError = error.localizedDescription
            }
        }
        try requireCurrentMediaOperation(generation)

        if let resumePosition {
            resumeNotice = ResumeNotice(position: resumePosition)
            latestEnginePosition = resumePosition
            snapshot.currentTime = resumePosition
        }

        do {
            try await engine.load(
                MediaLoadRequest(
                    playbackID: playbackID,
                    url: url,
                    startPosition: resumePosition,
                    autoplay: autoplay
                )
            )
            try requireCurrentMediaOperation(generation)
        } catch {
            try requireCurrentMediaOperation(generation)
            let playbackError = PlaybackError.wrapping(
                error,
                fallbackCode: .unsupportedMedia,
                recoverySuggestion: "Choose another video."
            )
            lastError = playbackError
            snapshot.phase = .failed
            releaseSecurityScopedResources()
            throw playbackError
        }
    }

    public func closeMedia() async {
        let generation = beginMediaOperation()
        await saveProgress(ifCurrentMediaOperationIs: generation)
        guard isCurrentMediaOperation(generation) else { return }
        do {
            try await engine.stop()
        } catch {
            guard isCurrentMediaOperation(generation) else { return }
            lastError = PlaybackError.wrapping(
                error,
                fallbackCode: .commandFailed,
                recoverySuggestion: "Try closing the video again."
            )
            snapshot.phase = .failed
            return
        }
        guard isCurrentMediaOperation(generation) else { return }
        activePlaybackID = nil
        releaseSecurityScopedResources()
        resetTransientState()
        snapshot = .empty
    }

    /// Call from application termination handling before the app exits.
    public func shutdown() async {
        await closeMedia()
        eventTask?.cancel()
        eventTask = nil
    }

    public func play() async throws {
        if phase == .ended {
            try await seek(to: 0)
        }
        try await performCommand { try await engine.play() }
    }

    public func pause() async throws {
        try await performCommand { try await engine.pause() }
        await saveProgress()
    }

    public func togglePlayback() async throws {
        if phase == .playing {
            try await pause()
        } else {
            try await play()
        }
    }

    public func seek(to seconds: TimeInterval) async throws {
        let target = clampedPosition(seconds)
        latestEnginePosition = target
        snapshot.currentTime = target
        lastPositionPublishedAt = now()
        try await performCommand { try await engine.seek(to: target) }
    }

    public func seek(by seconds: TimeInterval) async throws {
        guard seconds.isFinite else { return }
        let target = clampedPosition(latestEnginePosition + seconds)
        latestEnginePosition = target
        snapshot.currentTime = target
        lastPositionPublishedAt = now()
        try await performCommand { try await engine.seek(by: seconds) }
    }

    public func setVolume(_ normalizedVolume: Double) async throws {
        let volume = min(max(normalizedVolume.isFinite ? normalizedVolume : snapshot.volume, 0), 1)
        snapshot.volume = volume
        try await performCommand { try await engine.setVolume(volume) }
    }

    public func setMuted(_ muted: Bool) async throws {
        snapshot.isMuted = muted
        try await performCommand { try await engine.setMuted(muted) }
    }

    public func setRate(_ rate: Double) async throws {
        let safeRate = min(max(rate.isFinite ? rate : 1, 0.25), 4)
        snapshot.rate = safeRate
        try await performCommand { try await engine.setRate(safeRate) }
    }

    public func setVideoScaling(_ mode: VideoScalingMode) async throws {
        snapshot.videoScaling = mode
        try await performCommand { try await engine.setVideoScaling(mode) }
    }

    public func selectTrack(id: Int64?, kind: TrackKind) async throws {
        try await performCommand { try await engine.selectTrack(id: id, kind: kind) }
    }

    public func selectChapter(index: Int) async throws {
        guard snapshot.chapters.contains(where: { $0.index == index }) else { return }
        try await performCommand { try await engine.selectChapter(index: index) }
    }

    public func addExternalSubtitle(_ url: URL) async throws {
        let access = resourceAccessor.beginAccessing(url)
        do {
            try await performCommand { try await engine.addExternalSubtitle(url) }
            subtitleAccesses.append(access)
        } catch {
            access.stop()
            throw error
        }
    }

    public func beginScrubbing() {
        guard canSeek, scrubPosition == nil else { return }
        scrubPosition = snapshot.currentTime
    }

    public func updateScrubPosition(_ seconds: TimeInterval) {
        guard scrubPosition != nil else { return }
        scrubPosition = clampedPosition(seconds)
    }

    public func commitScrubbing() async throws {
        guard let target = scrubPosition else { return }
        scrubPosition = nil
        try await seek(to: target)
    }

    public func cancelScrubbing() {
        scrubPosition = nil
    }

    public func dismissResumeNotice() {
        resumeNotice = nil
    }

    public func restartFromBeginning() async throws {
        resumeNotice = nil
        try await seek(to: 0)
    }

    public func saveProgress() async {
        await saveProgress(ifCurrentMediaOperationIs: nil)
    }

    private func saveProgress(ifCurrentMediaOperationIs generation: UInt64?) async {
        let expectedGeneration = generation ?? mediaOperationGeneration
        let expectedPlaybackID = activePlaybackID
        if !isCurrentMediaOperation(expectedGeneration) {
            return
        }
        guard let historyStore,
              let url = snapshot.mediaURL,
              snapshot.phase != .idle,
              snapshot.phase != .loading,
              snapshot.phase != .failed
        else { return }

        let timestamp = now()
        let duration = latestEngineDuration ?? snapshot.duration
        let isCompleted = snapshot.phase == .ended
        let position = isCompleted ? (duration ?? latestEnginePosition) : latestEnginePosition
        let entry = PlaybackHistoryEntry(
            url: url,
            bookmarkData: currentBookmarkData,
            position: position,
            duration: duration,
            updatedAt: timestamp,
            isCompleted: isCompleted
        )

        do {
            try await historyStore.upsert(entry)
            if !isCurrentMediaOperation(expectedGeneration)
                || activePlaybackID != expectedPlaybackID {
                return
            }
            lastProgressSavedAt = timestamp
            lastPersistenceError = nil
        } catch {
            if !isCurrentMediaOperation(expectedGeneration)
                || activePlaybackID != expectedPlaybackID {
                return
            }
            lastPersistenceError = error.localizedDescription
        }
    }

    private func consume(_ event: PlayerEvent) async {
        guard let activePlaybackID, event.playbackID == activePlaybackID else {
            return
        }

        switch event.payload {
        case let .snapshot(incoming):
            if let incomingURL = incoming.mediaURL,
               incomingURL != snapshot.mediaURL {
                return
            }
            latestEnginePosition = sanitizedTime(incoming.currentTime)
            latestEngineDuration = sanitizedOptionalTime(incoming.duration)

            var next = incoming
            next.currentTime = snapshot.currentTime
            next.duration = snapshot.duration
            if shouldPublishPosition() {
                next.currentTime = latestEnginePosition
                next.duration = latestEngineDuration
                lastPositionPublishedAt = now()
            }
            if next != snapshot {
                snapshot = next
            }
            if incoming.phase == .paused || incoming.phase == .ended {
                await saveProgress()
            } else {
                await autosaveIfNeeded()
            }

        case let .phaseChanged(phase):
            snapshot.phase = phase
            if phase == .paused || phase == .ended {
                if phase == .ended, let duration = latestEngineDuration {
                    latestEnginePosition = duration
                    snapshot.currentTime = duration
                }
                await saveProgress()
            }

        case let .positionChanged(currentTime, duration):
            latestEnginePosition = sanitizedTime(currentTime)
            latestEngineDuration = sanitizedOptionalTime(duration) ?? latestEngineDuration
            if shouldPublishPosition() {
                snapshot.currentTime = latestEnginePosition
                snapshot.duration = latestEngineDuration
                lastPositionPublishedAt = now()
            }
            await autosaveIfNeeded()

        case let .bufferingChanged(isBuffering):
            snapshot.isBuffering = isBuffering

        case let .videoScalingChanged(mode):
            snapshot.videoScaling = mode

        case let .videoSizeChanged(size):
            snapshot.naturalVideoSize = size

        case let .volumeChanged(volume, isMuted):
            snapshot.volume = min(max(volume.isFinite ? volume : 1, 0), 1)
            snapshot.isMuted = isMuted

        case let .rateChanged(rate):
            snapshot.rate = rate.isFinite && rate > 0 ? rate : 1

        case let .tracksChanged(tracks):
            snapshot.tracks = tracks

        case let .chaptersChanged(chapters):
            snapshot.chapters = chapters.sorted { $0.index < $1.index }

        case let .mediaLoaded(url):
            guard url == snapshot.mediaURL else { return }
            snapshot.mediaURL = url
            if snapshot.phase == .loading {
                snapshot.phase = .ready
            }

        case .ended:
            snapshot.phase = .ended
            if let duration = latestEngineDuration {
                latestEnginePosition = duration
                snapshot.currentTime = duration
                snapshot.duration = duration
            }
            await saveProgress()

        case let .failed(error):
            lastError = error
            snapshot.phase = .failed
            releaseSecurityScopedResources()
        }
    }

    private func shouldPublishPosition() -> Bool {
        guard !isScrubbing else { return false }
        guard let lastPositionPublishedAt else { return true }
        return now().timeIntervalSince(lastPositionPublishedAt) >= configuration.positionPublishInterval
    }

    private func autosaveIfNeeded() async {
        guard historyStore != nil else { return }
        guard let lastProgressSavedAt else {
            // Start the five-second window when playback begins rather than writing every event.
            self.lastProgressSavedAt = now()
            return
        }
        if now().timeIntervalSince(lastProgressSavedAt) >= configuration.progressSaveInterval {
            await saveProgress()
        }
    }

    private func performCommand(_ operation: () async throws -> Void) async throws {
        do {
            try await operation()
            lastError = nil
        } catch {
            let playbackError = PlaybackError.wrapping(error, fallbackCode: .commandFailed)
            lastError = playbackError
            throw playbackError
        }
    }

    private func beginMediaOperation() -> UInt64 {
        mediaOperationGeneration &+= 1
        return mediaOperationGeneration
    }

    private func isCurrentMediaOperation(_ generation: UInt64) -> Bool {
        generation == mediaOperationGeneration
    }

    private func requireCurrentMediaOperation(_ generation: UInt64) throws {
        guard isCurrentMediaOperation(generation) else {
            throw CancellationError()
        }
    }

    private func clampedPosition(_ value: TimeInterval) -> TimeInterval {
        let safeValue = sanitizedTime(value)
        guard let duration = latestEngineDuration ?? snapshot.duration else {
            return safeValue
        }
        return min(safeValue, duration)
    }

    private func sanitizedTime(_ value: TimeInterval) -> TimeInterval {
        max(0, value.isFinite ? value : 0)
    }

    private func sanitizedOptionalTime(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private func resetTransientState() {
        resumeNotice = nil
        lastError = nil
        lastPersistenceError = nil
        scrubPosition = nil
        currentBookmarkData = nil
        latestEnginePosition = 0
        latestEngineDuration = nil
        lastPositionPublishedAt = nil
        lastProgressSavedAt = nil
    }

    private func releaseSecurityScopedResources() {
        mediaAccess?.stop()
        mediaAccess = nil
        subtitleAccesses.forEach { $0.stop() }
        subtitleAccesses.removeAll()
    }
}
