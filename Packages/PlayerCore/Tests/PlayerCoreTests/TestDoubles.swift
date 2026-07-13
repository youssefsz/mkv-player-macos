import Foundation
@testable import PlayerCore

final class FakePlayerEngine: PlayerEngine, @unchecked Sendable {
    enum Command: Sendable, Equatable {
        case load(MediaLoadRequest)
        case play
        case pause
        case seekTo(TimeInterval)
        case seekBy(TimeInterval)
        case volume(Double)
        case muted(Bool)
        case rate(Double)
        case videoScaling(VideoScalingMode)
        case track(Int64?, TrackKind)
        case chapter(Int)
        case subtitle(URL)
        case stop
    }

    let events: AsyncStream<PlayerEvent>

    private let continuation: AsyncStream<PlayerEvent>.Continuation
    private let loadGate: URLSuspensionGate?
    private let stopGate: OperationSuspensionGate?
    private let delayedLoadErrors: [URL: PlaybackError]
    private let lock = NSLock()
    private var recordedCommands: [Command] = []
    private var pendingError: PlaybackError?
    private var currentPlaybackID: UUID?

    init(
        loadGate: URLSuspensionGate? = nil,
        stopGate: OperationSuspensionGate? = nil,
        delayedLoadErrors: [URL: PlaybackError] = [:]
    ) {
        let pair = AsyncStream.makeStream(of: PlayerEvent.self)
        events = pair.stream
        continuation = pair.continuation
        self.loadGate = loadGate
        self.stopGate = stopGate
        self.delayedLoadErrors = delayedLoadErrors
    }

    var commands: [Command] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCommands
    }

    func emit(_ event: PlayerEvent) {
        lock.lock()
        let playbackID = currentPlaybackID
        lock.unlock()
        if event.playbackID == nil, let playbackID {
            continuation.yield(event.withPlaybackID(playbackID))
        } else {
            continuation.yield(event)
        }
    }

    func failNextCommand(with error: PlaybackError) {
        lock.lock()
        pendingError = error
        lock.unlock()
    }

    func load(_ request: MediaLoadRequest) async throws {
        setCurrentPlaybackID(request.playbackID)
        try record(.load(request))
        await loadGate?.waitIfSuspended(request.url)
        if let error = delayedLoadErrors[request.url] {
            throw error
        }
    }

    func play() async throws {
        try record(.play)
    }

    func pause() async throws {
        try record(.pause)
    }

    func seek(to seconds: TimeInterval) async throws {
        try record(.seekTo(seconds))
    }

    func seek(by seconds: TimeInterval) async throws {
        try record(.seekBy(seconds))
    }

    func setVolume(_ normalizedVolume: Double) async throws {
        try record(.volume(normalizedVolume))
    }

    func setMuted(_ muted: Bool) async throws {
        try record(.muted(muted))
    }

    func setRate(_ rate: Double) async throws {
        try record(.rate(rate))
    }

    func setVideoScaling(_ mode: VideoScalingMode) async throws {
        try record(.videoScaling(mode))
    }

    func selectTrack(id: Int64?, kind: TrackKind) async throws {
        try record(.track(id, kind))
    }

    func selectChapter(index: Int) async throws {
        try record(.chapter(index))
    }

    func addExternalSubtitle(_ url: URL) async throws {
        try record(.subtitle(url))
    }

    func stop() async throws {
        try record(.stop)
        await stopGate?.waitIfSuspended()
    }

    private func record(_ command: Command) throws {
        lock.lock()
        recordedCommands.append(command)
        let error = pendingError
        pendingError = nil
        lock.unlock()
        if let error {
            throw error
        }
    }

    private func setCurrentPlaybackID(_ playbackID: UUID) {
        lock.lock()
        currentPlaybackID = playbackID
        lock.unlock()
    }
}

actor OperationSuspensionGate {
    private var isSuspended = true
    private var didStart = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func waitIfSuspended() async {
        didStart = true
        let observers = startWaiters
        startWaiters.removeAll()
        observers.forEach { $0.resume() }
        guard isSuspended else { return }
        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resume() {
        isSuspended = false
        let waiters = operationWaiters
        operationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

actor InMemoryHistoryStore: PlaybackHistoryStoring {
    private var entries: [String: PlaybackHistoryEntry]
    private let lookupGate: URLSuspensionGate?
    private(set) var upsertCount = 0

    init(
        entries: [PlaybackHistoryEntry] = [],
        lookupGate: URLSuspensionGate? = nil
    ) {
        self.entries = Dictionary(uniqueKeysWithValues: entries.map { ($0.mediaKey, $0) })
        self.lookupGate = lookupGate
    }

    func entry(for mediaKey: String) async -> PlaybackHistoryEntry? {
        await lookupGate?.waitIfSuspended(URL(fileURLWithPath: mediaKey))
        return entries[mediaKey]
    }

    func allEntries() -> [PlaybackHistoryEntry] {
        entries.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    func upsert(_ entry: PlaybackHistoryEntry) {
        entries[entry.mediaKey] = entry
        upsertCount += 1
    }

    func remove(mediaKey: String) {
        entries.removeValue(forKey: mediaKey)
    }

    func removeAll() {
        entries.removeAll()
    }

    func numberOfUpserts() -> Int {
        upsertCount
    }
}

/// Deterministically suspends selected URL operations until a test resumes them.
actor URLSuspensionGate {
    private var suspendedURLs: Set<URL>
    private var startedURLs: Set<URL> = []
    private var operationWaiters: [URL: [CheckedContinuation<Void, Never>]] = [:]
    private var startWaiters: [URL: [CheckedContinuation<Void, Never>]] = [:]

    init(suspending urls: Set<URL>) {
        suspendedURLs = urls
    }

    func waitIfSuspended(_ url: URL) async {
        startedURLs.insert(url)
        let observers = startWaiters.removeValue(forKey: url) ?? []
        observers.forEach { $0.resume() }

        guard suspendedURLs.contains(url) else { return }
        await withCheckedContinuation { continuation in
            operationWaiters[url, default: []].append(continuation)
        }
    }

    func waitUntilStarted(_ url: URL) async {
        guard !startedURLs.contains(url) else { return }
        await withCheckedContinuation { continuation in
            startWaiters[url, default: []].append(continuation)
        }
    }

    func resume(_ url: URL) {
        suspendedURLs.remove(url)
        let waiters = operationWaiters.removeValue(forKey: url) ?? []
        waiters.forEach { $0.resume() }
    }
}

struct FakeBookmarkProvider: BookmarkProviding {
    let data: Data

    init(data: Data = Data([4, 2])) {
        self.data = data
    }

    func makeBookmark(for url: URL) throws -> Data { data }

    func resolveBookmark(_ data: Data) throws -> ResolvedBookmark {
        ResolvedBookmark(url: URL(fileURLWithPath: "/resolved.mkv"), isStale: false)
    }
}

final class ResourceAccessRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var startedURLs: [URL] = []
    private var stoppedURLs: [URL] = []

    var started: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return startedURLs
    }

    var stopped: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return stoppedURLs
    }

    func recordStart(_ url: URL) {
        lock.lock()
        startedURLs.append(url)
        lock.unlock()
    }

    func recordStop(_ url: URL) {
        lock.lock()
        stoppedURLs.append(url)
        lock.unlock()
    }
}

struct FakeResourceAccessor: SecurityScopedResourceAccessing {
    let recorder: ResourceAccessRecorder

    func beginAccessing(_ url: URL) -> any SecurityScopedResourceAccess {
        recorder.recordStart(url)
        return FakeResourceAccess(url: url, recorder: recorder)
    }
}

private final class FakeResourceAccess: SecurityScopedResourceAccess, @unchecked Sendable {
    let url: URL
    let didAcquireSecurityScope = true

    private let recorder: ResourceAccessRecorder
    private let lock = NSLock()
    private var stopped = false

    init(url: URL, recorder: ResourceAccessRecorder) {
        self.url = url
        self.recorder = recorder
    }

    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        lock.unlock()
        recorder.recordStop(url)
    }
}

final class TestDateClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date = Date(timeIntervalSince1970: 1_000)) {
        self.value = value
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(interval)
        lock.unlock()
    }
}

@MainActor
func eventually(
    timeoutIterations: Int = 100,
    _ condition: @MainActor () -> Bool
) async -> Bool {
    for _ in 0..<timeoutIterations {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

@MainActor
func eventuallyAsync(
    timeoutIterations: Int = 100,
    _ condition: @MainActor () async -> Bool
) async -> Bool {
    for _ in 0..<timeoutIterations {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}
