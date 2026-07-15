import AppKit
import MPVKit
import OSLog
import Sparkle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let logger = Logger(subsystem: "io.github.youssefsz.MKVPlayer", category: "lifecycle")
    private var playerWindowController: PlayerWindowController?
    private var playerBootstrapTask: Task<Void, Never>?
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    private lazy var settingsWindowController = SettingsWindowController(updater: updaterController.updater)
    private lazy var menuController = AppMenuController(commandTarget: self)
    private var isTerminating = false
    private var updaterIsStarted = false
    private var didFinishLaunching = false
    private var shouldPresentPlayerWhenReady = true
    private var shouldOpenPanelWhenReady = false
    private var pendingVideoURLs: [URL] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        logger.notice("applicationWillFinishLaunching")
        _ = updaterController
        _ = startUpdaterIfConfigured()
        _ = menuController
        menuController.refresh(
            state: PlayerPresentationState(),
            recentURLs: []
        )
        startPlayerBootstrap()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.notice("applicationDidFinishLaunching")
        didFinishLaunching = true
        if let playerWindowController {
            playerWindowController.present()
            logPlayerVisibility(playerWindowController)
        } else {
            shouldPresentPlayerWhenReady = true
            startPlayerBootstrap()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        shouldPresentPlayerWhenReady = true
        if let playerWindowController,
           playerWindowController.window?.isVisible != true {
            playerWindowController.present()
        } else if playerWindowController == nil {
            startPlayerBootstrap()
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        logger.debug("Received \(urls.count) file-open URL(s)")
        let videoURLs = urls.filter(Self.isSupportedVideo)
        guard !videoURLs.isEmpty else {
            logger.debug("The file-open request did not contain a supported video")
            return
        }
        logger.notice("Opening a video from Launch Services")
        shouldPresentPlayerWhenReady = true
        if let playerWindowController {
            playerWindowController.open(videoURLs)
        } else {
            pendingVideoURLs = videoURLs
            startPlayerBootstrap()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        shouldPresentPlayerWhenReady = false
        let bootstrapTask = playerBootstrapTask
        Task { @MainActor [weak self, weak sender] in
            guard let self else {
                sender?.reply(toApplicationShouldTerminate: true)
                return
            }
            await bootstrapTask?.value
            if let playerWindowController = self.playerWindowController {
                await playerWindowController.shutdown()
            }
            sender?.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @objc func openVideo(_ sender: Any?) {
        if let playerWindowController {
            playerWindowController.openPanel()
        } else {
            shouldOpenPanelWhenReady = true
            shouldPresentPlayerWhenReady = true
            startPlayerBootstrap()
        }
    }

    @objc func addSubtitle(_ sender: Any?) {
        playerWindowController?.subtitlePanel()
    }

    @objc func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        playerWindowController?.open(url)
    }

    @objc func clearRecent(_ sender: Any?) {
        playerWindowController?.clearRecentFiles()
    }

    @objc func togglePlayback(_ sender: Any?) {
        playerWindowController?.togglePlayback()
    }

    @objc func seekBackward(_ sender: Any?) {
        playerWindowController?.seek(by: -10)
    }

    @objc func seekForward(_ sender: Any?) {
        playerWindowController?.seek(by: 10)
    }

    @objc func setPlaybackRate(_ sender: NSMenuItem) {
        guard let rate = sender.representedObject as? Double else { return }
        playerWindowController?.setPlaybackRate(rate)
    }

    @objc func selectAudioTrack(_ sender: NSMenuItem) {
        if let identifier = sender.representedObject as? Int64 {
            playerWindowController?.selectAudioTrack(identifier)
        } else if let number = sender.representedObject as? NSNumber {
            playerWindowController?.selectAudioTrack(number.int64Value)
        }
    }

    @objc func selectSubtitleTrack(_ sender: NSMenuItem) {
        if let identifier = sender.representedObject as? Int64 {
            playerWindowController?.selectSubtitleTrack(identifier)
        } else if let number = sender.representedObject as? NSNumber {
            playerWindowController?.selectSubtitleTrack(number.int64Value)
        }
    }

    @objc func disableSubtitles(_ sender: Any?) {
        playerWindowController?.selectSubtitleTrack(nil)
    }

    @objc func selectChapter(_ sender: NSMenuItem) {
        if let index = sender.representedObject as? Int {
            playerWindowController?.selectChapter(index)
        } else if let number = sender.representedObject as? NSNumber {
            playerWindowController?.selectChapter(number.intValue)
        }
    }

    @objc func fitVideo(_ sender: Any?) {
        playerWindowController?.setVideoScaling(.fit)
    }

    @objc func fillVideo(_ sender: Any?) {
        playerWindowController?.setVideoScaling(.fill)
    }

    @objc func showVideoAtActualSize(_ sender: Any?) {
        playerWindowController?.setVideoScaling(.actualSize)
    }

    @objc func toggleFullScreen(_ sender: Any?) {
        playerWindowController?.toggleFullScreen()
    }

    @objc func showSettings(_ sender: Any?) {
        settingsWindowController.present()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        guard startUpdaterIfConfigured() else {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Updates are unavailable in this development build."
            alert.informativeText = "Release builds include a signed Sparkle public key and update feed."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        updaterController.checkForUpdates(sender)
    }

    @objc func openProjectWebsite(_ sender: Any?) {
        openWebPage("https://github.com/youssefsz/mkv-player-macos")
    }

    @objc func reportIssue(_ sender: Any?) {
        openWebPage("https://github.com/youssefsz/mkv-player-macos/issues/new/choose")
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let state = playerWindowController?.presentationState ?? PlayerPresentationState()
        switch menuItem.action {
        case #selector(addSubtitle(_:)),
             #selector(selectAudioTrack(_:)),
             #selector(selectSubtitleTrack(_:)),
             #selector(disableSubtitles(_:)):
            return state.canControlPlayback
        case #selector(togglePlayback(_:)):
            switch state.phase {
            case .ready, .playing, .paused, .ended: return true
            case .idle, .loading, .failed: return false
            }
        case #selector(seekBackward(_:)),
             #selector(seekForward(_:)),
             #selector(selectChapter(_:)):
            return state.canSeek
        case #selector(setPlaybackRate(_:)),
             #selector(fitVideo(_:)),
             #selector(fillVideo(_:)):
            return state.canControlPlayback
        case #selector(toggleFullScreen(_:)):
            menuItem.title = playerWindowController?.window?.styleMask.contains(.fullScreen) == true
                ? "Exit Full Screen"
                : "Enter Full Screen"
            return playerWindowController?.window != nil
        case #selector(showVideoAtActualSize(_:)):
            return state.canControlPlayback
                && state.naturalVideoWidth != nil
                && state.naturalVideoHeight != nil
        default:
            return true
        }
    }

    private func openWebPage(_ address: String) {
        guard let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url)
    }

    /// libmpv performs dynamic loading and core initialization synchronously.
    /// Build it on a detached executor, then install only the native window and
    /// presentation objects on the main actor.
    private func startPlayerBootstrap() {
        guard playerWindowController == nil, playerBootstrapTask == nil else { return }

        playerBootstrapTask = Task { @MainActor [weak self] in
            let engine = await Task.detached(priority: .userInitiated) {
                MPVEngine()
            }.value

            guard let self, !isTerminating else { return }
            let controller = PlayerWindowController(engine: engine)
            playerWindowController = controller
            controller.presentationDidChange = { [weak self] state, recentURLs in
                self?.menuController.refresh(state: state, recentURLs: recentURLs)
            }
            menuController.refresh(
                state: controller.presentationState,
                recentURLs: controller.recentURLs
            )

            if !pendingVideoURLs.isEmpty {
                let urls = pendingVideoURLs
                pendingVideoURLs = []
                shouldOpenPanelWhenReady = false
                controller.open(urls)
            } else if shouldOpenPanelWhenReady {
                shouldOpenPanelWhenReady = false
                controller.openPanel()
            } else if didFinishLaunching, shouldPresentPlayerWhenReady {
                controller.present()
            }
            logPlayerVisibility(controller)
        }
    }

    private func logPlayerVisibility(_ controller: PlayerWindowController) {
        logger.notice("player window visible: \(controller.window?.isVisible == true)")
    }

    @discardableResult
    private func startUpdaterIfConfigured() -> Bool {
        if updaterIsStarted { return true }

        let publicKey = (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let feed = (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !publicKey.isEmpty,
              !publicKey.contains("$("),
              let feedURL = URL(string: feed),
              feedURL.scheme == "https"
        else {
            logger.info("Skipping Sparkle startup because this build has no release update key")
            return false
        }

        updaterController.startUpdater()
        updaterIsStarted = true
        return true
    }

    private static func isSupportedVideo(_ url: URL) -> Bool {
        ["mkv", "mp4", "m4v", "mov", "webm", "avi", "ts", "m2ts"]
            .contains(url.pathExtension.lowercased())
    }
}
