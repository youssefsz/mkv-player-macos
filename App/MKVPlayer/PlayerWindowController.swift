import AppKit
import Combine
import MPVKit
import OSLog
import PlayerCore
import UniformTypeIdentifiers

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
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = Self.videoExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in self?.open(url) }
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
        guard Self.videoExtensions.contains(url.pathExtension.lowercased()) else {
            NSSound.beep()
            return
        }

        recoverableCommandError = nil

        recentURLs.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        recentURLs.insert(url, at: 0)
        recentURLs = Array(recentURLs.prefix(10))
        recentFilesController.noteOpened(url)
        notifyPresentationChanged()
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        present()

        perform { [session, preferences] in
            try await session.open(
                url,
                autoplay: preferences.autoplays,
                allowResume: preferences.resumesPlayback
            )
        }

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            await self?.reloadRecentFiles(keeping: url)
        }
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
        perform { [session] in try await session.seek(by: offset) }
    }

    func setVolume(_ volume: Double) {
        perform { [session] in try await session.setVolume(volume / 100) }
    }

    func toggleMute() {
        perform { [session] in try await session.setMuted(!session.snapshot.isMuted) }
    }

    func selectAudioTrack(_ id: Int64) {
        perform { [session] in try await session.selectTrack(id: id, kind: .audio) }
    }

    func selectSubtitleTrack(_ id: Int64?) {
        perform { [session] in try await session.selectTrack(id: id, kind: .subtitle) }
    }

    func selectChapter(_ index: Int) {
        perform { [session] in try await session.selectChapter(index: index) }
    }

    func setPlaybackRate(_ rate: Double) {
        perform { [session] in try await session.setRate(rate) }
    }

    func setVideoScaling(_ mode: VideoScalingMode) {
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
        state.isFullScreen = window?.styleMask.contains(.fullScreen) == true
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
    func playerWindowDidRequestSeek(by offset: TimeInterval) { seek(by: offset) }

    func playerWindowDidRequestEscape() {
        if window?.styleMask.contains(.fullScreen) == true { toggleFullScreen() }
        else { playerViewController.showControls() }
    }
}

extension PlayerWindowController: PlayerViewControllerDelegate {
    func playerViewControllerDidRequestOpenPanel(_ controller: PlayerViewController) { openPanel() }
    func playerViewController(_ controller: PlayerViewController, didOpen url: URL) { open(url) }
    func playerViewController(_ controller: PlayerViewController, didAddSubtitle url: URL) { addSubtitle(url) }
    func playerViewControllerDidRequestTogglePlayback(_ controller: PlayerViewController) { togglePlayback() }
    func playerViewController(_ controller: PlayerViewController, didRequestRelativeSeek offset: TimeInterval) { seek(by: offset) }
    func playerViewControllerDidBeginScrubbing(_ controller: PlayerViewController) { session.beginScrubbing() }
    func playerViewController(_ controller: PlayerViewController, didUpdateScrubbing position: TimeInterval) { session.updateScrubPosition(position) }
    func playerViewControllerDidCommitScrubbing(_ controller: PlayerViewController) {
        perform { [session] in try await session.commitScrubbing() }
    }
    func playerViewController(_ controller: PlayerViewController, didChangeVolume volume: Double) { setVolume(volume) }
    func playerViewControllerDidRequestToggleMute(_ controller: PlayerViewController) { toggleMute() }
    func playerViewController(_ controller: PlayerViewController, didSelectAudioTrack id: Int64) { selectAudioTrack(id) }
    func playerViewController(_ controller: PlayerViewController, didSelectSubtitleTrack id: Int64?) { selectSubtitleTrack(id) }
    func playerViewController(_ controller: PlayerViewController, didSelectChapter index: Int) { selectChapter(index) }
    func playerViewControllerDidRequestFullScreen(_ controller: PlayerViewController) { toggleFullScreen() }
    func playerViewControllerDidRequestRestart(_ controller: PlayerViewController) {
        perform { [session] in try await session.restartFromBeginning() }
    }
    func playerViewControllerDidDismissRecoverableError(_ controller: PlayerViewController) {
        dismissRecoverableError()
    }
}
