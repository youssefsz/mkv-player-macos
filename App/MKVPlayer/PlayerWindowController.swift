import AppKit
import Combine
import MPVKit
import OSLog
import PlayerCore
import UniformTypeIdentifiers

private struct PlaybackQueueItem: Equatable {
    let id: UUID
    let url: URL
}

@MainActor
final class PlayerWindowController: NSWindowController {
    private static let videoExtensions = ["mkv", "mp4", "m4v", "mov", "webm", "avi", "ts", "m2ts"]
    private static let subtitleExtensions = [
        "srt", "ass", "ssa", "vtt", "sub", "sup", "idx", "smi", "sami", "ttml", "dfxp", "lrc"
    ]

    let engine: MPVEngine
    let session: PlayerSession

    var presentationDidChange: ((PlayerPresentationState, [URL]) -> Void)?

    private let playerViewController: PlayerViewController
    private let recentFilesController: RecentFilesController
    private let preferences = PlayerPreferences()
    private let activityController = PlaybackActivityController()
    private let logger = Logger(subsystem: "io.github.youssefsz.MKVPlayer", category: "playback")
    private var cancellables: Set<AnyCancellable> = []
    private var lastLoggedPhase: PlayerPresentationPhase = .idle
    private var recoverableCommandError: PlaybackError?
    private var operationGeneration: UInt64 = 0
    private var selectedPlaybackRate: Double = 1
    private var preferredVolume: Double = 1
    private var preferredMuted = false
    private var preferredVideoScaling: VideoScalingMode = .fit
    private var isTemporaryFastPlaybackActive = false
    private var keyboardSeekGesture = KeyboardSeekGesture()
    private var playbackQueue: [PlaybackQueueItem] = []
    private var currentQueueIndex: Int?
    private var activeQueueLoadID: UUID?
    private var lastObservedPhase: PlayerPresentationPhase = .idle
    private(set) var recentURLs: [URL] = []
    private(set) var presentationState = PlayerPresentationState()

    init(engine: MPVEngine) {
        let historyStore = try? JSONPlaybackHistoryStore(
            applicationIdentifier: "io.github.youssefsz.MKVPlayer",
            maximumEntryCount: 100
        )
        let session = PlayerSession(engine: engine, historyStore: historyStore)
        let viewController = PlayerViewController()
        let recentFilesController = RecentFilesController(historyStore: historyStore)

        self.engine = engine
        self.session = session
        self.playerViewController = viewController
        self.recentFilesController = recentFilesController

        let window = PlayerWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MKV Player"
        window.minSize = NSSize(width: 540, height: 340)
        window.backgroundColor = .windowBackgroundColor
        window.collectionBehavior = [.fullScreenPrimary]
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("MainPlayerWindow")

        super.init(window: window)

        window.contentViewController = viewController
        window.delegate = self
        window.playbackKeyboardDelegate = self
        viewController.delegate = self
        viewController.installVideoView(MPVVideoSurface(engine: engine))
        bindSession()
        renderCurrentState()

        Task { [weak self] in
            await self?.reloadRecentFiles()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openPanel() {
        guard let window else { return }
        if !window.isVisible { present() }
        let panel = NSOpenPanel()
        panel.title = "Open Video"
        panel.prompt = "Open"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = Self.videoExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            let urls = panel.urls
            Task { @MainActor [weak self] in self?.open(urls) }
        }
    }

    func subtitlePanel() {
        guard presentationState.canControlPlayback, let window else { return }
        let panel = NSOpenPanel()
        panel.title = "Add Subtitle File"
        panel.prompt = "Add Subtitle"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = Self.subtitleExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in self?.addSubtitle(url) }
        }
    }

    func open(_ url: URL) {
        open([url])
    }

    func open(_ urls: [URL]) {
        guard let error = validateVideoURLs(urls) else {
            playbackQueue = urls.map { PlaybackQueueItem(id: UUID(), url: $0) }
            currentQueueIndex = nil
            startQueueItem(at: 0, allowResume: true)
            return
        }
        presentRecoverableError(error)
    }

    private func startQueueItem(
        at index: Int,
        allowResume: Bool,
        autoplayOverride: Bool? = nil
    ) {
        guard playbackQueue.indices.contains(index) else { return }
        let item = playbackQueue[index]
        let previousURL = session.currentMediaURL?.standardizedFileURL
        let shouldResume = allowResume && previousURL != item.url.standardizedFileURL
        let loadID = UUID()
        activeQueueLoadID = loadID
        currentQueueIndex = index

        recoverableCommandError = nil
        keyboardSeekGesture.reset()
        playerViewController.prepareForMediaReplacement()
        if isTemporaryFastPlaybackActive {
            isTemporaryFastPlaybackActive = false
            playerViewController.setTemporaryFastPlaybackActive(false)
        }

        recentURLs.removeAll { $0.standardizedFileURL == item.url.standardizedFileURL }
        recentURLs.insert(item.url, at: 0)
        recentURLs = Array(recentURLs.prefix(10))
        recentFilesController.noteOpened(item.url)
        notifyPresentationChanged()
        NSDocumentController.shared.noteNewRecentDocumentURL(item.url)
        present()

        let volume = preferredVolume
        let muted = preferredMuted
        let rate = selectedPlaybackRate
        let scaling = preferredVideoScaling
        perform { [weak self, session, preferences] in
            do {
                try await session.open(
                    item.url,
                    autoplay: autoplayOverride ?? preferences.autoplays,
                    allowResume: shouldResume && preferences.resumesPlayback
                )
                guard self?.activeQueueLoadID == loadID else { return }
                try await session.setVolume(volume)
                guard self?.activeQueueLoadID == loadID else { return }
                try await session.setMuted(muted)
                guard self?.activeQueueLoadID == loadID else { return }
                try await session.setRate(rate)
                guard self?.activeQueueLoadID == loadID else { return }
                try await session.setVideoScaling(scaling)
                if self?.activeQueueLoadID == loadID {
                    self?.activeQueueLoadID = nil
                }
            } catch {
                if self?.activeQueueLoadID == loadID {
                    self?.activeQueueLoadID = nil
                }
                throw error
            }
        }

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            await self?.reloadRecentFiles(keeping: item.url)
        }
    }

    private func validateVideoURLs(_ urls: [URL]) -> PlaybackError? {
        guard !urls.isEmpty else {
            return PlaybackError(
                code: .unsupportedMedia,
                message: "No video was selected.",
                recoverySuggestion: "Choose a video file."
            )
        }

        for url in urls {
            guard url.isFileURL,
                  !url.lastPathComponent.isEmpty,
                  Self.videoExtensions.contains(url.pathExtension.lowercased())
            else {
                return PlaybackError(
                    code: .unsupportedMedia,
                    message: "“\(url.lastPathComponent)” is not a supported video file.",
                    recoverySuggestion: "Choose an MKV, MP4, MOV, WebM, AVI, TS, or M2TS video."
                )
            }

            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else {
                return PlaybackError(
                    code: .fileNotFound,
                    message: "“\(url.lastPathComponent)” could not be found.",
                    recoverySuggestion: "Choose another video."
                )
            }

            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attributes[.size] as? NSNumber,
               size.int64Value == 0 {
                return PlaybackError(
                    code: .corruptMedia,
                    message: "“\(url.lastPathComponent)” is empty and can’t be played.",
                    recoverySuggestion: "Choose another video."
                )
            }
        }
        return nil
    }

    func addSubtitle(_ url: URL) {
        guard Self.subtitleExtensions.contains(url.pathExtension.lowercased()) else {
            presentRecoverableError(
                PlaybackError(
                    code: .unsupportedMedia,
                    message: "This subtitle format is not supported.",
                    diagnostics: "Unsupported subtitle extension: \(url.pathExtension.lowercased())"
                )
            )
            return
        }
        guard presentationState.canControlPlayback else { return }
        perform { [session] in try await session.addExternalSubtitle(url) }
    }

    func togglePlayback() {
        guard session.canPlayOrPause else { return }
        perform { [session] in try await session.togglePlayback() }
    }

    func seek(by offset: TimeInterval) {
        guard session.canSeek else { return }
        keyboardSeekGesture.reset()
        perform { [session] in try await session.seek(by: offset) }
    }

    func setVolume(_ volume: Double) {
        preferredVolume = min(max(volume / 100, 0), 1)
        perform { [session] in try await session.setVolume(volume / 100) }
    }

    func toggleMute() {
        preferredMuted.toggle()
        let muted = preferredMuted
        perform { [session] in try await session.setMuted(muted) }
    }

    func selectAudioTrack(_ id: Int64) {
        perform { [session] in try await session.selectTrack(id: id, kind: .audio) }
    }

    func selectSubtitleTrack(_ id: Int64?) {
        perform { [session] in try await session.selectTrack(id: id, kind: .subtitle) }
    }

    func selectChapter(_ index: Int) {
        keyboardSeekGesture.reset()
        perform { [session] in try await session.selectChapter(index: index) }
    }

    func setPlaybackRate(_ rate: Double) {
        guard rate.isFinite, rate > 0 else { return }
        selectedPlaybackRate = rate
        renderCurrentState()
        guard !isTemporaryFastPlaybackActive else { return }
        perform { [session] in try await session.setRate(rate) }
    }

    private func beginTemporaryFastPlayback() {
        guard presentationState.canControlPlayback,
              !isTemporaryFastPlaybackActive else { return }
        isTemporaryFastPlaybackActive = true
        playerViewController.setTemporaryFastPlaybackActive(true)
        perform { [session] in try await session.setRate(2) }
    }

    private func endTemporaryFastPlayback() {
        guard isTemporaryFastPlaybackActive else { return }
        isTemporaryFastPlaybackActive = false
        playerViewController.setTemporaryFastPlaybackActive(false)
        let rate = selectedPlaybackRate
        perform { [session] in try await session.setRate(rate) }
    }

    func setVideoScaling(_ mode: VideoScalingMode) {
        preferredVideoScaling = mode
        perform { [weak self, session] in
            try await session.setVideoScaling(mode)
            if mode == .actualSize { self?.resizeToNaturalVideoSize() }
        }
    }

    func toggleFullScreen() {
        window?.toggleFullScreen(nil)
    }

    func clearRecentFiles() {
        recentURLs = []
        recentFilesController.clear()
        NSDocumentController.shared.clearRecentDocuments(nil)
        notifyPresentationChanged()
    }

    func shutdown() async {
        await session.shutdown()
        activityController.setPlaying(false)
    }

    private func bindSession() {
        session.$snapshot
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.renderCurrentState() }
            }
            .store(in: &cancellables)
        session.$scrubPosition
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.renderCurrentState() }
            }
            .store(in: &cancellables)
        session.$lastError
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.renderCurrentState() }
            }
            .store(in: &cancellables)
        session.$resumeNotice
            .sink { [weak self] notice in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let notice { self.playerViewController.showResume(position: notice.position) }
                    else { self.playerViewController.hideResume() }
                }
            }
            .store(in: &cancellables)
    }

    private func renderCurrentState() {
        var state = PlayerPresentationState(
            snapshot: session.snapshot,
            displayedPosition: session.displayedPosition,
            error: session.lastError
        )
        // The controls and app menu continue to show the user's persistent
        // selections while a replacement resets the session snapshot and
        // Space temporarily overrides the engine rate.
        state.rate = selectedPlaybackRate
        state.volume = preferredVolume * 100
        state.isMuted = preferredMuted
        state.videoScaling = switch preferredVideoScaling {
        case .fit: .fit
        case .fill: .fill
        case .actualSize: .actualSize
        }
        state.isFullScreen = window?.styleMask.contains(.fullScreen) == true
        let transitionedToEnd = state.phase == .ended && lastObservedPhase != .ended
        lastObservedPhase = state.phase

        if transitionedToEnd,
           activeQueueLoadID == nil,
           let currentQueueIndex,
           playbackQueue.indices.contains(currentQueueIndex + 1) {
            startQueueItem(
                at: currentQueueIndex + 1,
                allowResume: false,
                autoplayOverride: true
            )
            state.phase = .loading
            state.position = 0
            state.duration = 0
            state.isSeekable = false
        } else if activeQueueLoadID != nil, state.phase == .ended {
            state.phase = .loading
        }

        state.queueItems = playbackQueue.enumerated().map { index, item in
            PlayerQueueItemPresentation(
                id: item.id,
                url: item.url,
                isCurrent: index == currentQueueIndex
            )
        }
        if session.snapshot.phase != .failed, let recoverableCommandError {
            let message = [
                recoverableCommandError.message,
                recoverableCommandError.recoverySuggestion
            ]
                .compactMap { $0 }
                .joined(separator: " ")
            let diagnostics = [
                recoverableCommandError.message,
                recoverableCommandError.diagnostics
            ]
                .compactMap { $0 }
                .joined(separator: "\n")
            state.recoverableError = PlayerRecoverableErrorPresentation(
                message: message,
                diagnostics: diagnostics
            )
            state.diagnostics = diagnostics
        }
        presentationState = state
        if state.phase != lastLoggedPhase {
            logger.notice("Playback phase changed to \(String(describing: state.phase), privacy: .public)")
            lastLoggedPhase = state.phase
        }
        playerViewController.render(state)
        window?.title = state.title
        window?.representedURL = state.fileURL
        activityController.setPlaying(state.isPlaying)
        notifyPresentationChanged()
    }

    private func selectQueueItem(id: UUID) {
        guard let index = playbackQueue.firstIndex(where: { $0.id == id }),
              index != currentQueueIndex
        else { return }
        startQueueItem(at: index, allowResume: false, autoplayOverride: true)
    }

    private func removeQueueItem(id: UUID) {
        guard let removedIndex = playbackQueue.firstIndex(where: { $0.id == id }) else { return }
        let removedCurrentItem = removedIndex == currentQueueIndex
        playbackQueue.remove(at: removedIndex)

        guard !playbackQueue.isEmpty else {
            currentQueueIndex = nil
            activeQueueLoadID = nil
            perform { [session] in await session.closeMedia() }
            renderCurrentState()
            return
        }

        if removedCurrentItem {
            currentQueueIndex = nil
            startQueueItem(
                at: min(removedIndex, playbackQueue.count - 1),
                allowResume: false,
                autoplayOverride: true
            )
        } else {
            if let currentQueueIndex, removedIndex < currentQueueIndex {
                self.currentQueueIndex = currentQueueIndex - 1
            }
            renderCurrentState()
        }
    }

    private func playPreviousQueueItem() {
        guard let currentQueueIndex, currentQueueIndex > 0 else { return }
        startQueueItem(at: currentQueueIndex - 1, allowResume: false, autoplayOverride: true)
    }

    private func playNextQueueItem() {
        guard let currentQueueIndex,
              playbackQueue.indices.contains(currentQueueIndex + 1)
        else { return }
        startQueueItem(at: currentQueueIndex + 1, allowResume: false, autoplayOverride: true)
    }

    private func notifyPresentationChanged() {
        presentationDidChange?(presentationState, recentURLs)
    }

    private func reloadRecentFiles(keeping currentURL: URL? = nil) async {
        var urls = await recentFilesController.loadRecentURLs()
        if let currentURL {
            urls.removeAll { $0.standardizedFileURL == currentURL.standardizedFileURL }
            urls.insert(currentURL, at: 0)
        }
        recentURLs = Array(urls.prefix(10))
        notifyPresentationChanged()
    }

    private func resizeToNaturalVideoSize() {
        guard let width = presentationState.naturalVideoWidth,
              let height = presentationState.naturalVideoHeight,
              width > 0, height > 0,
              let window
        else { return }

        var size = NSSize(width: width, height: height)
        if let visible = window.screen?.visibleFrame.size {
            let maximum = NSSize(width: visible.width * 0.9, height: visible.height * 0.9)
            let scale = min(1, maximum.width / size.width, maximum.height / size.height)
            size.width *= scale
            size.height *= scale
        }
        window.setContentSize(size)
        window.center()
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        operationGeneration &+= 1
        let generation = operationGeneration
        Task { @MainActor in
            do {
                try await operation()
                guard generation == self.operationGeneration else { return }
                self.recoverableCommandError = nil
                self.renderCurrentState()
            } catch is CancellationError {
                // Replacing one in-flight open with another is expected.
            } catch let error as PlaybackError where error.code == .cancelled {
                // The engine also reports superseded render-wait requests this way.
            } catch {
                guard generation == self.operationGeneration else { return }
                self.logger.error("Playback operation failed: \(error.localizedDescription, privacy: .public)")
                if self.session.snapshot.phase == .failed {
                    self.renderCurrentState()
                } else {
                    self.presentRecoverableError(
                        PlaybackError.wrapping(
                            error,
                            fallbackCode: .commandFailed,
                            recoverySuggestion: "Playback can continue."
                        )
                    )
                }
            }
        }
    }

    private func presentRecoverableError(_ error: PlaybackError) {
        recoverableCommandError = error
        renderCurrentState()
        NSSound.beep()
    }

    private func dismissRecoverableError() {
        recoverableCommandError = nil
        renderCurrentState()
    }
}

extension PlayerWindowController: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        playbackQueue = []
        currentQueueIndex = nil
        activeQueueLoadID = nil
        Task { [session] in await session.closeMedia() }
        return true
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        renderCurrentState()
        playerViewController.showControls()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        renderCurrentState()
        playerViewController.showControls()
    }
}

extension PlayerWindowController: PlayerWindowKeyboardDelegate {
    func playerWindowDidRequestControls() { playerViewController.showControls() }
    func playerWindowDidRequestTogglePlayback() { togglePlayback() }
    func playerWindowDidRequestSeek(by offset: TimeInterval) {
        guard presentationState.canSeek else { return }
        guard let result = keyboardSeekGesture.apply(
            step: offset,
            position: presentationState.position,
            duration: presentationState.duration
        ) else { return }
        playerViewController.showKeyboardSeekFeedback(offset: result.displayedOffset)
        perform { [session] in try await session.seek(to: result.target) }
    }
    func playerWindowDidBeginTemporaryFastPlayback() { beginTemporaryFastPlayback() }
    func playerWindowDidEndTemporaryFastPlayback() { endTemporaryFastPlayback() }

    func playerWindowDidRequestEscape() {
        if window?.styleMask.contains(.fullScreen) == true { toggleFullScreen() }
        else { playerViewController.showControls() }
    }
}

extension PlayerWindowController: PlayerViewControllerDelegate {
    func playerViewControllerDidRequestOpenPanel(_ controller: PlayerViewController) { openPanel() }
    func playerViewController(_ controller: PlayerViewController, didOpen urls: [URL]) { open(urls) }
    func playerViewController(_ controller: PlayerViewController, didAddSubtitle url: URL) { addSubtitle(url) }
    func playerViewController(_ controller: PlayerViewController, didRejectDrop message: String) {
        presentRecoverableError(
            PlaybackError(
                code: .unsupportedMedia,
                message: message,
                recoverySuggestion: "Drop a supported video file instead."
            )
        )
    }
    func playerViewControllerDidRequestTogglePlayback(_ controller: PlayerViewController) { togglePlayback() }
    func playerViewController(_ controller: PlayerViewController, didRequestRelativeSeek offset: TimeInterval) { seek(by: offset) }
    func playerViewControllerDidBeginScrubbing(_ controller: PlayerViewController) {
        keyboardSeekGesture.reset()
        session.beginScrubbing()
    }
    func playerViewController(_ controller: PlayerViewController, didUpdateScrubbing position: TimeInterval) { session.updateScrubPosition(position) }
    func playerViewControllerDidCommitScrubbing(_ controller: PlayerViewController) {
        perform { [session] in try await session.commitScrubbing() }
    }
    func playerViewController(_ controller: PlayerViewController, didChangeVolume volume: Double) { setVolume(volume) }
    func playerViewControllerDidRequestToggleMute(_ controller: PlayerViewController) { toggleMute() }
    func playerViewController(_ controller: PlayerViewController, didChangePlaybackRate rate: Double) {
        setPlaybackRate(rate)
    }
    func playerViewController(_ controller: PlayerViewController, didSelectAudioTrack id: Int64) { selectAudioTrack(id) }
    func playerViewController(_ controller: PlayerViewController, didSelectSubtitleTrack id: Int64?) { selectSubtitleTrack(id) }
    func playerViewController(_ controller: PlayerViewController, didSelectChapter index: Int) { selectChapter(index) }
    func playerViewControllerDidRequestFullScreen(_ controller: PlayerViewController) { toggleFullScreen() }
    func playerViewControllerDidRequestRestart(_ controller: PlayerViewController) {
        keyboardSeekGesture.reset()
        perform { [session] in try await session.restartFromBeginning() }
    }
    func playerViewControllerDidRequestReplay(_ controller: PlayerViewController) {
        perform { [session] in try await session.play() }
    }
    func playerViewController(_ controller: PlayerViewController, didSelectQueueItem id: UUID) {
        selectQueueItem(id: id)
    }
    func playerViewController(_ controller: PlayerViewController, didRemoveQueueItem id: UUID) {
        removeQueueItem(id: id)
    }
    func playerViewControllerDidRequestPreviousQueueItem(_ controller: PlayerViewController) {
        playPreviousQueueItem()
    }
    func playerViewControllerDidRequestNextQueueItem(_ controller: PlayerViewController) {
        playNextQueueItem()
    }
    func playerViewControllerDidDismissRecoverableError(_ controller: PlayerViewController) {
        dismissRecoverableError()
    }
}
