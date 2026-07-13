import AppKit

final class PlayerCanvasView: NSView {
    var onOpenVideo: ((URL) -> Void)?
    var onOpenPanel: (() -> Void)?
    var onAddSubtitle: ((URL) -> Void)?
    var onChooseAnother: (() -> Void)?
    var onCopyDiagnostics: (() -> Void)?
    var onDismissRecoverableError: (() -> Void)?
    var onScrubbingChanged: ((Bool) -> Void)?

    let controls = PlaybackControlsView(frame: .zero)
    let resumeBanner = ResumeBannerView(frame: .zero)

    private let videoContainer = NSView(frame: .zero)
    private let emptyState = EmptyStateView(frame: .zero)
    private let errorState = ErrorStateView(frame: .zero)
    private let loadingIndicator = NSProgressIndicator(frame: .zero)
    private var trackingArea: NSTrackingArea?
    private var hideControlsTimer: Timer?
    private var hideResumeTimer: Timer?
    private var isScrubbing = false
    private var latestState = PlayerPresentationState()

    private static let videoExtensions: Set<String> = ["mkv", "mp4", "m4v", "mov", "webm", "avi", "ts", "m2ts"]
    private static let subtitleExtensions: Set<String> = [
        "srt", "ass", "ssa", "vtt", "sub", "sup", "idx", "smi", "sami", "ttml", "dfxp", "lrc"
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        registerForDraggedTypes([.fileURL])

        videoContainer.translatesAutoresizingMaskIntoConstraints = false
        videoContainer.wantsLayer = true
        videoContainer.layer?.backgroundColor = NSColor.black.cgColor
        addSubview(videoContainer)

        emptyState.onOpen = { [weak self] in self?.onOpenPanel?() }
        addSubview(emptyState)

        errorState.isHidden = true
        errorState.onChooseAnother = { [weak self] in self?.onChooseAnother?() }
        errorState.onCopyDiagnostics = { [weak self] in self?.onCopyDiagnostics?() }
        errorState.onDismiss = { [weak self] in self?.onDismissRecoverableError?() }
        addSubview(errorState)

        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .large
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.isDisplayedWhenStopped = false
        addSubview(loadingIndicator)

        controls.alphaValue = 1
        controls.onScrubbingChanged = { [weak self] scrubbing in
            self?.isScrubbing = scrubbing
            self?.onScrubbingChanged?(scrubbing)
            if scrubbing { self?.showControls(scheduleHide: false) }
            else { self?.scheduleControlsHideIfNeeded() }
        }
        addSubview(controls)

        resumeBanner.isHidden = true
        addSubview(resumeBanner)

        NSLayoutConstraint.activate([
            videoContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            videoContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            videoContainer.topAnchor.constraint(equalTo: topAnchor),
            videoContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyState.leadingAnchor.constraint(equalTo: leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: topAnchor),
            emptyState.bottomAnchor.constraint(equalTo: bottomAnchor),

            errorState.centerXAnchor.constraint(equalTo: centerXAnchor),
            errorState.centerYAnchor.constraint(equalTo: centerYAnchor),
            errorState.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            errorState.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),

            loadingIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),

            controls.centerXAnchor.constraint(equalTo: centerXAnchor),
            controls.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            controls.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            controls.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),

            resumeBanner.centerXAnchor.constraint(equalTo: centerXAnchor),
            resumeBanner.topAnchor.constraint(equalTo: topAnchor, constant: 16)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        showControls(scheduleHide: true)
    }

    override func mouseEntered(with event: NSEvent) {
        showControls(scheduleHide: true)
    }

    override func mouseExited(with event: NSEvent) {
        scheduleControlsHideIfNeeded()
    }

    func installVideoView(_ view: NSView) {
        videoContainer.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        videoContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: videoContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: videoContainer.trailingAnchor),
            view.topAnchor.constraint(equalTo: videoContainer.topAnchor),
            view.bottomAnchor.constraint(equalTo: videoContainer.bottomAnchor)
        ])
    }

    func render(_ state: PlayerPresentationState) {
        latestState = state
        let displaysVideo = state.hasMedia || state.phase == .loading
        layer?.backgroundColor = displaysVideo
            ? NSColor.black.cgColor
            : NSColor.windowBackgroundColor.cgColor
        videoContainer.isHidden = !displaysVideo
        controls.render(state)
        emptyState.isHidden = state.hasMedia || state.phase == .loading
        if !state.hasMedia {
            controls.isHidden = true
            controls.alphaValue = 1
        }

        switch state.phase {
        case .loading:
            loadingIndicator.startAnimation(nil)
            showControls(scheduleHide: false)
        case let .failed(message):
            loadingIndicator.stopAnimation(nil)
            errorState.present(message: message, kind: .fatal)
            showControls(scheduleHide: false)
        case .idle:
            loadingIndicator.stopAnimation(nil)
            resumeBanner.isHidden = true
            hideControlsTimer?.invalidate()
        case .playing:
            loadingIndicator.stopAnimation(nil)
            scheduleControlsHideIfNeeded()
        case .ready, .paused, .ended:
            loadingIndicator.stopAnimation(nil)
            showControls(scheduleHide: false)
        }

        if case .failed = state.phase {
            // Fatal errors are configured in the phase switch above.
        } else if let recoverableError = state.recoverableError {
            errorState.present(message: recoverableError.message, kind: .recoverable)
            showControls(scheduleHide: false)
        } else {
            errorState.isHidden = true
        }

        if state.isBuffering && state.hasMedia {
            loadingIndicator.startAnimation(nil)
        } else if state.phase != .loading {
            loadingIndicator.stopAnimation(nil)
        }
    }

    func showResume(position: TimeInterval) {
        hideResumeTimer?.invalidate()
        let message = resumeBanner.show(position: position)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15
            resumeBanner.animator().alphaValue = 1
        }
        NSAccessibility.post(
            element: resumeBanner,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSNumber(value: NSAccessibilityPriorityLevel.medium.rawValue)
            ]
        )
        guard !NSWorkspace.shared.isVoiceOverEnabled else {
            hideResumeTimer = nil
            return
        }
        hideResumeTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if NSWorkspace.shared.isVoiceOverEnabled {
                    self.hideResumeTimer = nil
                } else {
                    self.hideResume()
                }
            }
        }
    }

    func hideResume() {
        hideResumeTimer?.invalidate()
        hideResumeTimer = nil
        resumeBanner.isHidden = true
    }

    func showControls(scheduleHide: Bool) {
        guard latestState.hasMedia else { return }
        hideControlsTimer?.invalidate()
        controls.isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            controls.animator().alphaValue = 1
        }
        if scheduleHide { scheduleControlsHideIfNeeded(restart: true) }
    }

    private func scheduleControlsHideIfNeeded(restart: Bool = false) {
        if !restart, hideControlsTimer?.isValid == true { return }
        guard !controls.isHidden else { return }
        hideControlsTimer?.invalidate()
        guard latestState.isPlaying,
              !isScrubbing,
              !NSWorkspace.shared.isVoiceOverEnabled,
              !controlsContainsFirstResponder,
              !controls.hasActiveMenu else { return }

        hideControlsTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.hideControlsTimer = nil
                self?.hideControls()
            }
        }
    }

    private func hideControls() {
        guard latestState.isPlaying,
              !isScrubbing,
              !NSWorkspace.shared.isVoiceOverEnabled,
              !controlsContainsFirstResponder,
              !controls.hasActiveMenu else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
            controls.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.controls.alphaValue == 0 else { return }
                self.controls.isHidden = true
            }
        }
    }

    private var controlsContainsFirstResponder: Bool {
        guard let firstResponder = window?.firstResponder as? NSView else { return false }
        return firstResponder === controls || firstResponder.isDescendant(of: controls)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        acceptedURL(from: sender) == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = acceptedURL(from: sender) else { return false }
        let ext = url.pathExtension.lowercased()
        if Self.subtitleExtensions.contains(ext), latestState.canControlPlayback {
            onAddSubtitle?(url)
        } else {
            onOpenVideo?(url)
        }
        return true
    }

    private func acceptedURL(from sender: NSDraggingInfo) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
        return urls?.first { url in
            let ext = url.pathExtension.lowercased()
            return Self.videoExtensions.contains(ext)
                || (latestState.canControlPlayback && Self.subtitleExtensions.contains(ext))
        }
    }
}

private extension NSView {
    var hasActiveMenu: Bool {
        if let popUp = self as? NSPopUpButton, popUp.menu?.highlightedItem != nil { return true }
        return subviews.contains(where: \.hasActiveMenu)
    }
}
