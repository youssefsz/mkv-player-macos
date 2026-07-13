import Foundation
import PlayerCore

internal final class MPVEventPump: @unchecked Sendable {
    private let client: MPVClient
    private let sink: MPVEventSink
    private let commandBroker: MPVAsyncCommandBroker
    private let queue = DispatchQueue(
        label: "player.mpv.events",
        qos: .userInteractive
    )
    private let stateLock = NSLock()
    private var stopped = false
    private var started = false
    private var currentEntryID: Int64?

    init(
        client: MPVClient,
        sink: MPVEventSink,
        commandBroker: MPVAsyncCommandBroker
    ) {
        self.client = client
        self.sink = sink
        self.commandBroker = commandBroker
    }

    func start() {
        stateLock.lock()
        guard !started else {
            stateLock.unlock()
            return
        }
        started = true
        stateLock.unlock()

        queue.async { [weak self] in
            self?.run()
        }
    }

    func stop() {
        stateLock.lock()
        stopped = true
        stateLock.unlock()
        client.wakeup()
    }

    private func run() {
        while !isStopped {
            let event = client.waitForEvent(timeout: 0.25)
            guard !isStopped else {
                break
            }
            handle(event)
        }
    }

    private var isStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }

    private func handle(_ event: MPVRawEvent) {
        switch event {
        case .none, .other, .seek, .playbackRestart:
            break
        case let .commandReply(error, replyID):
            if error >= 0 {
                commandBroker.resolve(replyID: replyID, result: .success(()))
            } else {
                commandBroker.resolve(
                    replyID: replyID,
                    result: .failure(
                        PlaybackError(
                            code: .commandFailed,
                            message: client.errorMessage(for: error),
                            diagnostics: "libmpv command error \(error)"
                        )
                    )
                )
            }
        case .shutdown:
            let error = PlaybackError(
                code: .engineUnavailable,
                message: "The playback engine shut down."
            )
            commandBroker.failAll(with: error)
            sink.shutdown(with: error)
            stop()
        case let .startFile(entryID):
            currentEntryID = entryID
            sink.fileDidStart(entryID: entryID, path: client.stringProperty("path"))
        case let .endFile(reason, error, entryID):
            if currentEntryID == entryID {
                currentEntryID = nil
            }
            handleEndFile(reason: reason, error: error, entryID: entryID)
        case .fileLoaded:
            guard let currentEntryID else {
                return
            }
            sink.mediaLoaded(
                entryID: currentEntryID,
                path: client.stringProperty("path"),
                isPaused: client.boolProperty("pause") ?? true
            )
            refreshPosition()
            refreshVolume()
            refreshRate()
            refreshBuffering()
            refreshVideoSize()
            refreshTracks()
            refreshChapters()
            sink.setSeekable(client.boolProperty("seekable") ?? false)
        case .tracksChanged:
            refreshTracks()
        case .idle:
            currentEntryID = nil
            sink.becameIdle()
        case .pause:
            sink.setPhase(.paused)
        case .unpause:
            sink.setPhase(.playing)
        case let .propertyChanged(name):
            handlePropertyChange(name)
        case .chapterChanged:
            refreshChapters()
        }
    }

    private func handlePropertyChange(_ name: String) {
        switch name {
        case "pause":
            guard let paused = client.boolProperty("pause") else {
                return
            }
            sink.setPhase(paused ? .paused : .playing)
        case "eof-reached":
            if client.boolProperty("eof-reached") == true {
                refreshPosition()
                sink.ended(entryID: currentEntryID)
            }
        case "time-pos", "duration":
            refreshPosition()
        case "seekable":
            sink.setSeekable(client.boolProperty("seekable") ?? false)
        case "paused-for-cache":
            refreshBuffering()
        case "idle-active":
            if client.boolProperty("idle-active") == true {
                currentEntryID = nil
                sink.becameIdle()
            }
        case "video-params":
            refreshVideoSize()
        case "volume", "mute":
            refreshVolume()
        case "speed":
            refreshRate()
        case "track-list":
            refreshTracks()
        case "chapter-list":
            refreshChapters()
        default:
            break
        }
    }

    private func refreshPosition() {
        sink.setPosition(
            currentTime: client.doubleProperty("time-pos") ?? 0,
            duration: client.doubleProperty("duration")
        )
    }

    private func refreshVolume() {
        let volume = (client.doubleProperty("volume") ?? 100) / 100
        let muted = client.boolProperty("mute") ?? false
        sink.setVolume(volume, muted: muted)
    }

    private func refreshRate() {
        guard let rate = client.doubleProperty("speed") else {
            return
        }
        sink.setRate(rate)
    }

    private func refreshBuffering() {
        sink.setBuffering(client.boolProperty("paused-for-cache") ?? false)
    }

    private func refreshVideoSize() {
        guard let width = client.integerProperty("video-params/dw"),
              let height = client.integerProperty("video-params/dh")
        else {
            sink.setVideoSize(nil)
            return
        }
        sink.setVideoSize(
            VideoDimensions(width: Int(width), height: Int(height))
        )
    }

    private func refreshTracks() {
        let count = max(0, min(Int(client.integerProperty("track-list/count") ?? 0), 1_024))
        var tracks: [TrackDescriptor] = []
        tracks.reserveCapacity(count)

        for index in 0 ..< count {
            let prefix = "track-list/\(index)"
            guard let id = client.integerProperty("\(prefix)/id"),
                  let rawType = client.stringProperty("\(prefix)/type"),
                  let kind = trackKind(rawType)
            else {
                continue
            }

            tracks.append(
                TrackDescriptor(
                    id: id,
                    kind: kind,
                    title: client.stringProperty("\(prefix)/title"),
                    languageCode: client.stringProperty("\(prefix)/lang"),
                    codec: client.stringProperty("\(prefix)/codec"),
                    isSelected: client.boolProperty("\(prefix)/selected") ?? false,
                    isDefault: client.boolProperty("\(prefix)/default") ?? false,
                    isForced: client.boolProperty("\(prefix)/forced") ?? false,
                    isExternal: client.boolProperty("\(prefix)/external") ?? false
                )
            )
        }
        sink.setTracks(tracks)
    }

    private func refreshChapters() {
        let count = max(0, min(Int(client.integerProperty("chapter-list/count") ?? 0), 10_000))
        var chapters: [ChapterDescriptor] = []
        chapters.reserveCapacity(count)

        for index in 0 ..< count {
            let prefix = "chapter-list/\(index)"
            guard let time = client.doubleProperty("\(prefix)/time") else {
                continue
            }
            chapters.append(
                ChapterDescriptor(
                    index: index,
                    title: client.stringProperty("\(prefix)/title"),
                    startTime: time
                )
            )
        }
        sink.setChapters(chapters)
    }

    private func handleEndFile(reason: Int32, error: Int32, entryID: Int64?) {
        switch reason {
        case 0: // MPV_END_FILE_REASON_EOF
            sink.ended(entryID: entryID)
        case 2, 3: // STOP or QUIT
            sink.stopped(entryID: entryID)
        case 4: // ERROR
            sink.fail(
                PlaybackError(
                    code: Self.playbackErrorCode(forMPVError: error),
                    message: "The video could not be played.",
                    diagnostics: client.errorMessage(for: error),
                    recoverySuggestion: "The file may be damaged or use an unsupported codec."
                ),
                entryID: entryID
            )
        case 5: // REDIRECT; not used by the local-file product.
            break
        default:
            sink.fail(
                PlaybackError(
                    code: .unknown,
                    message: "Playback ended unexpectedly.",
                    diagnostics: "libmpv end-file reason \(reason), error \(error)"
                ),
                entryID: entryID
            )
        }
    }

    /// libmpv distinguishes unsupported formats/codecs from files that were
    /// recognized but could not produce playable media. File existence and
    /// sandbox readability have already been checked by `MPVEngine.load`.
    internal static func playbackErrorCode(forMPVError error: Int32) -> PlaybackError.Code {
        switch error {
        case -17, -18: // MPV_ERROR_UNKNOWN_FORMAT, MPV_ERROR_UNSUPPORTED
            .unsupportedMedia
        case -13, -16, -20: // LOADING_FAILED, NOTHING_TO_PLAY, GENERIC
            .corruptMedia
        default:
            .unknown
        }
    }

    private func trackKind(_ rawValue: String) -> TrackKind? {
        switch rawValue {
        case "video": .video
        case "audio": .audio
        case "sub": .subtitle
        default: nil
        }
    }
}

internal final class MPVEventSink: @unchecked Sendable {
    internal struct StopToken: Hashable, Sendable {
        fileprivate let id = UUID()
    }

    private typealias Waiter = CheckedContinuation<Void, any Error>

    private struct PendingRequest: Sendable {
        let request: MediaLoadRequest
        let normalizedPath: String
    }

    private struct Entry: Sendable {
        let entryID: Int64
        let request: MediaLoadRequest
        let normalizedPath: String
    }

    private struct StopRequest: Sendable {
        let targetEntryID: Int64?
        let targetPlaybackID: UUID?
    }

    private let continuation: AsyncStream<PlayerEvent>.Continuation
    private let queue = DispatchQueue(label: "player.mpv.event-sink")

    // All state below is confined to `queue`. Events are yielded before the
    // next mutation begins, preserving state/event order across the engine and
    // libmpv event threads.
    private var snapshot = PlayerSnapshot.empty
    private var latestPlaybackID: UUID?
    private var pendingRequests: [PendingRequest] = []
    private var entries: [Int64: Entry] = [:]
    private var currentEntryID: Int64?
    private var stopRequests: [StopToken: StopRequest] = [:]

    private var loadWaiters: [UUID: Waiter] = [:]
    private var loadResults: [UUID: Result<Void, PlaybackError>] = [:]
    private var completedLoadIDs: Set<UUID> = []
    private var cancelledLoadWaits: Set<UUID> = []
    private var stopWaiters: [StopToken: Waiter] = [:]
    private var stopResults: [StopToken: Result<Void, PlaybackError>] = [:]
    private var cancelledStopWaits: Set<StopToken> = []
    private var terminalError: PlaybackError?

    init(continuation: AsyncStream<PlayerEvent>.Continuation) {
        self.continuation = continuation
    }

    var requiresStop: Bool {
        queue.sync {
            currentEntryID != nil || !pendingRequests.isEmpty || latestPlaybackID != nil
        }
    }

    func beginLoading(_ request: MediaLoadRequest) {
        queue.sync {
            // Keep terminal IDs only while a late load waiter still needs its
            // cached result. Once the previous media is stopped, retaining all
            // historical UUIDs would make this set grow for the app lifetime.
            let unconsumedLoadIDs = Set(loadResults.keys)
                .union(loadWaiters.keys)
                .union(cancelledLoadWaits)
            completedLoadIDs.formIntersection(unconsumedLoadIDs)

            let cancellation = PlaybackError(
                code: .cancelled,
                message: "A newer video replaced this request."
            )
            for pending in pendingRequests where pending.request.playbackID != request.playbackID {
                completeLoadLocked(pending.request.playbackID, with: .failure(cancellation))
            }

            latestPlaybackID = request.playbackID
            pendingRequests.removeAll { $0.request.playbackID == request.playbackID }
            pendingRequests.append(
                PendingRequest(
                    request: request,
                    normalizedPath: Self.normalizedPath(for: request.url)
                )
            )

            snapshot = PlayerSnapshot(
                phase: .loading,
                mediaURL: request.url,
                currentTime: request.startPosition ?? 0,
                videoScaling: snapshot.videoScaling,
                volume: snapshot.volume,
                isMuted: snapshot.isMuted,
                rate: snapshot.rate
            )
            yieldLocked(.phaseChanged(.loading, playbackID: request.playbackID))
            yieldLocked(.snapshot(snapshot, playbackID: request.playbackID))
        }
    }

    func waitUntilLoaded(playbackID: UUID) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiter in
                let result: Result<Void, PlaybackError>? = queue.sync {
                    if let terminalError {
                        return .failure(terminalError)
                    }
                    if cancelledLoadWaits.remove(playbackID) != nil {
                        return .failure(
                            PlaybackError(code: .cancelled, message: "Loading was cancelled.")
                        )
                    }
                    if let result = loadResults.removeValue(forKey: playbackID) {
                        return result
                    }
                    loadWaiters[playbackID] = waiter
                    return nil
                }
                if let result {
                    Self.resume(waiter, with: result)
                }
            }
        } onCancel: {
            cancelLoadWait(playbackID)
        }
    }

    func failLoad(playbackID: UUID, error: PlaybackError) {
        queue.sync {
            pendingRequests.removeAll { $0.request.playbackID == playbackID }
            completeLoadLocked(playbackID, with: .failure(error))
            completeMatchingStopsLocked(entryID: nil, playbackID: playbackID)
            guard latestPlaybackID == playbackID else { return }
            snapshot.phase = .failed
            yieldLocked(.failed(error, playbackID: playbackID))
            yieldLocked(.snapshot(snapshot, playbackID: playbackID))
        }
    }

    func fileDidStart(entryID: Int64, path: String?) {
        queue.sync {
            currentEntryID = entryID
            let entry = associateEntryLocked(entryID: entryID, path: path)
            guard let entry, entry.request.playbackID == latestPlaybackID else { return }
            guard snapshot.phase != .loading else { return }
            snapshot.phase = .loading
            yieldLocked(.phaseChanged(.loading, playbackID: entry.request.playbackID))
        }
    }

    func mediaLoaded(entryID: Int64, path: String?, isPaused: Bool) {
        queue.sync {
            currentEntryID = entryID
            guard let entry = entries[entryID] ?? associateEntryLocked(entryID: entryID, path: path),
                  Self.normalizedPath(forMPVPath: path) == entry.normalizedPath,
                  entry.request.playbackID == latestPlaybackID
            else {
                return
            }

            pendingRequests.removeAll { $0.request.playbackID != entry.request.playbackID }
            snapshot.mediaURL = entry.request.url
            snapshot.phase = isPaused ? .paused : .playing
            yieldLocked(.mediaLoaded(entry.request.url, playbackID: entry.request.playbackID))
            yieldLocked(.phaseChanged(snapshot.phase, playbackID: entry.request.playbackID))
            yieldLocked(.snapshot(snapshot, playbackID: entry.request.playbackID))
            completeLoadLocked(entry.request.playbackID, with: .success(()))
        }
    }

    func prepareToStop() -> StopToken {
        queue.sync {
            let token = StopToken()
            let targetPlaybackID = currentEntryID.flatMap { entries[$0]?.request.playbackID }
                ?? latestPlaybackID
            stopRequests[token] = StopRequest(
                targetEntryID: currentEntryID,
                targetPlaybackID: targetPlaybackID
            )

            let cancellation = PlaybackError(
                code: .cancelled,
                message: "Loading stopped before the video became ready."
            )
            if let targetPlaybackID {
                completeLoadLocked(targetPlaybackID, with: .failure(cancellation))
            }
            if currentEntryID == nil, pendingRequests.isEmpty {
                completeStopLocked(token, with: .success(()))
            }
            return token
        }
    }

    func waitUntilStopped(_ token: StopToken) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiter in
                let result: Result<Void, PlaybackError>? = queue.sync {
                    if let terminalError {
                        return .failure(terminalError)
                    }
                    if cancelledStopWaits.remove(token) != nil {
                        return .failure(
                            PlaybackError(code: .cancelled, message: "Stopping was cancelled.")
                        )
                    }
                    if let result = stopResults.removeValue(forKey: token) {
                        return result
                    }
                    stopWaiters[token] = waiter
                    return nil
                }
                if let result {
                    Self.resume(waiter, with: result)
                }
            }
        } onCancel: {
            cancelStopWait(token)
        }
    }

    func stopped(entryID: Int64?) {
        queue.sync {
            let entry = entryID.flatMap { entries.removeValue(forKey: $0) }
            if currentEntryID == entryID {
                currentEntryID = nil
            }
            if let entry {
                pendingRequests.removeAll { $0.request.playbackID == entry.request.playbackID }
                completeLoadLocked(
                    entry.request.playbackID,
                    with: .failure(
                        PlaybackError(code: .cancelled, message: "Loading was stopped.")
                    )
                )
            }
            completeMatchingStopsLocked(entryID: entryID, playbackID: entry?.request.playbackID)

            guard let playbackID = entry?.request.playbackID,
                  playbackID == latestPlaybackID,
                  !hasNewerPendingRequestLocked(than: playbackID)
            else { return }
            resetToIdleLocked(taggedWith: playbackID)
        }
    }

    func becameIdle() {
        queue.sync {
            let stoppedPlaybackIDs = Set(stopRequests.values.compactMap(\.targetPlaybackID))
            currentEntryID = nil
            entries.removeAll()
            pendingRequests.removeAll {
                stoppedPlaybackIDs.contains($0.request.playbackID)
            }
            for token in Array(stopRequests.keys) {
                completeStopLocked(token, with: .success(()))
            }

            if let latestPlaybackID,
               stoppedPlaybackIDs.contains(latestPlaybackID) {
                resetToIdleLocked(taggedWith: latestPlaybackID)
                return
            }
            if let latestPlaybackID,
               pendingRequests.contains(where: { $0.request.playbackID == latestPlaybackID }) {
                pendingRequests.removeAll { $0.request.playbackID != latestPlaybackID }
                return
            }
            if let latestPlaybackID {
                resetToIdleLocked(taggedWith: latestPlaybackID)
            }
        }
    }

    func setPhase(_ phase: PlaybackPhase) {
        queue.sync {
            guard let playbackID = activePlaybackIDLocked,
                  snapshot.mediaURL != nil,
                  snapshot.phase != .loading
            else { return }
            if snapshot.phase == .ended, phase == .paused { return }
            guard snapshot.phase != phase else { return }
            snapshot.phase = phase
            yieldLocked(.phaseChanged(phase, playbackID: playbackID))
        }
    }

    func setPosition(currentTime: TimeInterval, duration: TimeInterval?) {
        queue.sync {
            guard let playbackID = activePlaybackIDLocked else { return }
            let currentTime = max(0, currentTime.isFinite ? currentTime : 0)
            let duration = duration.flatMap { value in
                value.isFinite && value >= 0 ? value : nil
            }
            snapshot.currentTime = currentTime
            snapshot.duration = duration
            yieldLocked(
                .positionChanged(
                    currentTime: currentTime,
                    duration: duration,
                    playbackID: playbackID
                )
            )
        }
    }

    func setSeekable(_ seekable: Bool) {
        queue.sync {
            guard let playbackID = activePlaybackIDLocked,
                  snapshot.isSeekable != seekable
            else { return }
            snapshot.isSeekable = seekable
            yieldLocked(.snapshot(snapshot, playbackID: playbackID))
        }
    }

    func setBuffering(_ buffering: Bool) {
        queue.sync {
            guard let playbackID = activePlaybackIDLocked,
                  snapshot.isBuffering != buffering
            else { return }
            snapshot.isBuffering = buffering
            yieldLocked(.bufferingChanged(buffering, playbackID: playbackID))
        }
    }

    func setVideoScaling(_ mode: VideoScalingMode) {
        queue.sync {
            guard let playbackID = latestPlaybackID,
                  snapshot.videoScaling != mode
            else { return }
            snapshot.videoScaling = mode
            yieldLocked(.videoScalingChanged(mode, playbackID: playbackID))
        }
    }

    func setVideoSize(_ size: VideoDimensions?) {
        queue.sync {
            guard let playbackID = activePlaybackIDLocked,
                  snapshot.naturalVideoSize != size
            else { return }
            snapshot.naturalVideoSize = size
            yieldLocked(.videoSizeChanged(size, playbackID: playbackID))
        }
    }

    func setVolume(_ volume: Double, muted: Bool) {
        queue.sync {
            guard let playbackID = activePlaybackIDLocked else { return }
            let volume = min(max(volume.isFinite ? volume : 1, 0), 1)
            guard snapshot.volume != volume || snapshot.isMuted != muted else { return }
            snapshot.volume = volume
            snapshot.isMuted = muted
            yieldLocked(
                .volumeChanged(volume: volume, isMuted: muted, playbackID: playbackID)
            )
        }
    }

    func setRate(_ rate: Double) {
        queue.sync {
            guard let playbackID = activePlaybackIDLocked else { return }
            let rate = rate.isFinite && rate > 0 ? rate : 1
            guard snapshot.rate != rate else { return }
            snapshot.rate = rate
            yieldLocked(.rateChanged(rate, playbackID: playbackID))
        }
    }

    func setTracks(_ tracks: [TrackDescriptor]) {
        queue.sync {
            guard let playbackID = activePlaybackIDLocked,
                  snapshot.tracks != tracks
            else { return }
            snapshot.tracks = tracks
            yieldLocked(.tracksChanged(tracks, playbackID: playbackID))
        }
    }

    func setChapters(_ chapters: [ChapterDescriptor]) {
        queue.sync {
            guard let playbackID = activePlaybackIDLocked,
                  snapshot.chapters != chapters
            else { return }
            snapshot.chapters = chapters
            yieldLocked(.chaptersChanged(chapters, playbackID: playbackID))
        }
    }

    func ended(entryID: Int64?) {
        queue.sync {
            guard let entry = entryForEndLocked(entryID),
                  entry.request.playbackID == latestPlaybackID
            else { return }
            snapshot.phase = .ended
            if let duration = snapshot.duration {
                snapshot.currentTime = duration
            }
            yieldLocked(.ended(playbackID: entry.request.playbackID))
            yieldLocked(.snapshot(snapshot, playbackID: entry.request.playbackID))
        }
    }

    func fail(_ error: PlaybackError, entryID: Int64?) {
        queue.sync {
            guard let entry = entryForEndLocked(entryID) else {
                return
            }
            entries.removeValue(forKey: entry.entryID)
            if currentEntryID == entry.entryID {
                currentEntryID = nil
            }
            pendingRequests.removeAll { $0.request.playbackID == entry.request.playbackID }
            completeLoadLocked(entry.request.playbackID, with: .failure(error))
            completeMatchingStopsLocked(
                entryID: entry.entryID,
                playbackID: entry.request.playbackID
            )

            guard entry.request.playbackID == latestPlaybackID else { return }
            snapshot.phase = .failed
            yieldLocked(.failed(error, playbackID: entry.request.playbackID))
            yieldLocked(.snapshot(snapshot, playbackID: entry.request.playbackID))
        }
    }

    func abandonStop(_ token: StopToken) {
        queue.sync {
            stopRequests.removeValue(forKey: token)
            stopResults.removeValue(forKey: token)
            cancelledStopWaits.remove(token)
        }
    }

    func shutdown(with error: PlaybackError) {
        queue.sync {
            failAllWaitersLocked(with: error)
        }
    }

    func finish() {
        queue.sync {
            failAllWaitersLocked(
                with: PlaybackError(
                    code: .engineUnavailable,
                    message: "The playback engine was released."
                )
            )
            continuation.finish()
        }
    }

    private var activePlaybackIDLocked: UUID? {
        guard let currentEntryID,
              let entry = entries[currentEntryID],
              entry.request.playbackID == latestPlaybackID
        else { return nil }
        return entry.request.playbackID
    }

    @discardableResult
    private func associateEntryLocked(entryID: Int64, path: String?) -> Entry? {
        if let entry = entries[entryID] {
            return entry
        }
        guard let normalizedPath = Self.normalizedPath(forMPVPath: path),
              let index = pendingRequests.firstIndex(where: {
                  $0.normalizedPath == normalizedPath
              })
        else { return nil }

        let pending = pendingRequests.remove(at: index)
        let entry = Entry(
            entryID: entryID,
            request: pending.request,
            normalizedPath: pending.normalizedPath
        )
        entries[entryID] = entry
        return entry
    }

    private func entryForEndLocked(_ entryID: Int64?) -> Entry? {
        if let entryID, let entry = entries[entryID] {
            return entry
        }
        // A load can fail before `path` becomes readable. Event order still
        // makes a single pending request unambiguous, while multiple pending
        // requests are deliberately left unmatched rather than mis-tagged.
        guard let entryID, pendingRequests.count == 1 else { return nil }
        let pending = pendingRequests.removeFirst()
        let entry = Entry(
            entryID: entryID,
            request: pending.request,
            normalizedPath: pending.normalizedPath
        )
        entries[entryID] = entry
        return entry
    }

    private func hasNewerPendingRequestLocked(than playbackID: UUID) -> Bool {
        pendingRequests.contains { $0.request.playbackID != playbackID }
    }

    private func completeMatchingStopsLocked(entryID: Int64?, playbackID: UUID?) {
        let matching = stopRequests.compactMap { token, request -> StopToken? in
            if let targetEntryID = request.targetEntryID {
                return targetEntryID == entryID ? token : nil
            }
            if let targetPlaybackID = request.targetPlaybackID {
                return targetPlaybackID == playbackID ? token : nil
            }
            return token
        }
        for token in matching {
            completeStopLocked(token, with: .success(()))
        }
    }

    private func resetToIdleLocked(taggedWith playbackID: UUID) {
        latestPlaybackID = nil
        snapshot = .empty
        yieldLocked(.phaseChanged(.idle, playbackID: playbackID))
        yieldLocked(.snapshot(snapshot, playbackID: playbackID))
    }

    private func completeLoadLocked(
        _ playbackID: UUID,
        with result: Result<Void, PlaybackError>
    ) {
        guard completedLoadIDs.insert(playbackID).inserted else { return }
        if let waiter = loadWaiters.removeValue(forKey: playbackID) {
            Self.resume(waiter, with: result)
        } else {
            loadResults[playbackID] = result
        }
    }

    private func completeStopLocked(
        _ token: StopToken,
        with result: Result<Void, PlaybackError>
    ) {
        stopRequests.removeValue(forKey: token)
        guard stopResults[token] == nil else { return }
        if let waiter = stopWaiters.removeValue(forKey: token) {
            Self.resume(waiter, with: result)
        } else {
            stopResults[token] = result
        }
    }

    private func cancelLoadWait(_ playbackID: UUID) {
        let waiter: Waiter? = queue.sync {
            loadResults.removeValue(forKey: playbackID)
            if let waiter = loadWaiters.removeValue(forKey: playbackID) {
                return waiter
            }
            cancelledLoadWaits.insert(playbackID)
            return nil
        }
        waiter?.resume(throwing: CancellationError())
    }

    private func cancelStopWait(_ token: StopToken) {
        let waiter: Waiter? = queue.sync {
            stopResults.removeValue(forKey: token)
            stopRequests.removeValue(forKey: token)
            if let waiter = stopWaiters.removeValue(forKey: token) {
                return waiter
            }
            cancelledStopWaits.insert(token)
            return nil
        }
        waiter?.resume(throwing: CancellationError())
    }

    private func failAllWaitersLocked(with error: PlaybackError) {
        terminalError = error
        let loadWaiters = Array(loadWaiters.values)
        let stopWaiters = Array(stopWaiters.values)
        self.loadWaiters.removeAll()
        self.stopWaiters.removeAll()
        loadResults.removeAll()
        completedLoadIDs.removeAll()
        cancelledLoadWaits.removeAll()
        stopResults.removeAll()
        stopRequests.removeAll()
        cancelledStopWaits.removeAll()
        for waiter in loadWaiters + stopWaiters {
            waiter.resume(throwing: error)
        }
    }

    private func yieldLocked(_ event: PlayerEvent) {
        continuation.yield(event)
    }

    private static func resume(
        _ waiter: Waiter,
        with result: Result<Void, PlaybackError>
    ) {
        switch result {
        case .success:
            waiter.resume()
        case let .failure(error):
            waiter.resume(throwing: error)
        }
    }

    private static func normalizedPath(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    private static func normalizedPath(forMPVPath path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        if let url = URL(string: path), url.isFileURL, path.hasPrefix("file:") {
            return normalizedPath(for: url)
        }
        guard path.hasPrefix("/") else { return nil }
        return normalizedPath(for: URL(fileURLWithPath: path))
    }
}
