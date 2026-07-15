import AppKit

final class PlayerCanvasView: NSView {
    var onOpenVideos: (([URL]) -> Void)?
    var onOpenPanel: (() -> Void)?
    var onAddSubtitle: ((URL) -> Void)?
    var onInvalidFileDrop: ((String) -> Void)?
    var onChooseAnother: (() -> Void)?
    var onCopyDiagnostics: (() -> Void)?
    var onDismissRecoverableError: (() -> Void)?
    var onScrubbingChanged: ((Bool) -> Void)?
    var onReplay: (() -> Void)?
    var onSelectQueueItem: ((UUID) -> Void)?
    var onRemoveQueueItem: ((UUID) -> Void)?
    var onPreviousQueueItem: (() -> Void)?
    var onNextQueueItem: (() -> Void)?

    let controls = PlaybackControlsView(frame: .zero)
    let resumeBanner = ResumeBannerView(frame: .zero)

    private let videoContainer = NSView(frame: .zero)
    private let emptyState = EmptyStateView(frame: .zero)
    private let endState = EndStateView(frame: .zero)
    private let errorState = ErrorStateView(frame: .zero)
    private let queueView = PlaybackQueueView(frame: .zero)
    private let dropOverlay = DropOverlayView(frame: .zero)
    private let loadingIndicator = NSProgressIndicator(frame: .zero)
    private let temporarySpeedIndicator = PlaybackFeedbackView()
    private let seekIndicator = PlaybackFeedbackView()
    private var trackingArea: NSTrackingArea?
    private var hideControlsTimer: Timer?
    private var hideResumeTimer: Timer?
    private var hideSeekIndicatorTimer: Timer?
    private var isScrubbing = false
    private var isQueueVisible = false
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

        endState.isHidden = true
        endState.onReplay = { [weak self] in self?.onReplay?() }
        endState.onOpenAnother = { [weak self] in self?.onOpenPanel?() }
        addSubview(endState)

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

        temporarySpeedIndicator.isHidden = true
        addSubview(temporarySpeedIndicator)
        seekIndicator.isHidden = true
        addSubview(seekIndicator)

        controls.alphaValue = 1
        controls.onOpenVideo = { [weak self] in self?.onOpenPanel?() }
        controls.onToggleQueue = { [weak self] in self?.toggleQueue() }
        controls.onScrubbingChanged = { [weak self] scrubbing in
            self?.isScrubbing = scrubbing
            self?.onScrubbingChanged?(scrubbing)
            if scrubbing { self?.showControls(scheduleHide: false) }
            else { self?.scheduleControlsHideIfNeeded() }
        }
        addSubview(controls)

        queueView.isHidden = true
        queueView.onClose = { [weak self] in self?.setQueueVisible(false) }
        queueView.onPrevious = { [weak self] in self?.onPreviousQueueItem?() }
        queueView.onNext = { [weak self] in self?.onNextQueueItem?() }
        queueView.onSelectItem = { [weak self] id in self?.onSelectQueueItem?(id) }
        queueView.onRemoveItem = { [weak self] id in self?.onRemoveQueueItem?(id) }
        addSubview(queueView)

        resumeBanner.isHidden = true
        addSubview(resumeBanner)

        dropOverlay.isHidden = true
        addSubview(dropOverlay)

        NSLayoutConstraint.activate([
            videoContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            videoContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            videoContainer.topAnchor.constraint(equalTo: topAnchor),
            videoContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyState.leadingAnchor.constraint(equalTo: leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: topAnchor),
            emptyState.bottomAnchor.constraint(equalTo: bottomAnchor),

            endState.centerXAnchor.constraint(equalTo: centerXAnchor),
            endState.centerYAnchor.constraint(equalTo: centerYAnchor),
            endState.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            endState.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),

            errorState.centerXAnchor.constraint(equalTo: centerXAnchor),
            errorState.centerYAnchor.constraint(equalTo: centerYAnchor),
            errorState.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            errorState.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),

            loadingIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),

            temporarySpeedIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            temporarySpeedIndicator.topAnchor.constraint(equalTo: topAnchor, constant: 22),

            seekIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            seekIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),

            controls.centerXAnchor.constraint(equalTo: centerXAnchor),
            controls.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            controls.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            controls.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),

            queueView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            queueView.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            queueView.bottomAnchor.constraint(lessThanOrEqualTo: controls.topAnchor, constant: -12),
            queueView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),

            resumeBanner.centerXAnchor.constraint(equalTo: centerXAnchor),
            resumeBanner.topAnchor.constraint(equalTo: topAnchor, constant: 16),

            dropOverlay.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            dropOverlay.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            dropOverlay.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            dropOverlay.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
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
        queueView.render(state)
        if !state.hasQueue {
            setQueueVisible(false)
        }
        emptyState.isHidden = state.hasMedia || state.phase == .loading
        if !state.hasMedia {
            controls.isHidden = true
            controls.alphaValue = 1
            setTemporaryFastPlaybackActive(false)
            hideSeekIndicator()
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

        if state.phase == .ended {
            endState.present(filename: state.fileURL?.lastPathComponent)
        } else {
            endState.dismiss()
        }

        if case .failed = state.phase {
            // Fatal errors are configured in the phase switch above.
        } else if let recoverableError = state.recoverableError {
            errorState.present(
                message: recoverableError.message,
                kind: state.hasMedia ? .recoverable : .fatal
            )
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

    func setTemporaryFastPlaybackActive(_ isActive: Bool) {
        if isActive {
            temporarySpeedIndicator.present(text: "2×")
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.1
                temporarySpeedIndicator.animator().alphaValue = 1
            }
        } else {
            temporarySpeedIndicator.isHidden = true
            temporarySpeedIndicator.alphaValue = 0
        }
    }

    func showKeyboardSeekFeedback(offset: TimeInterval) {
        guard offset.isFinite, offset != 0 else { return }
        let roundedMagnitude = Int(abs(offset).rounded())
        let prefix = offset > 0 ? "+" : "−"
        let message = "\(prefix)\(roundedMagnitude)s"
        seekIndicator.present(text: message)
        seekIndicator.alphaValue = 1

        hideSeekIndicatorTimer?.invalidate()
        let timer = Timer(timeInterval: 0.75, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.hideSeekIndicator() }
        }
        hideSeekIndicatorTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func prepareForMediaReplacement() {
        hideResume()
        setTemporaryFastPlaybackActive(false)
        hideSeekIndicator()
        endState.dismiss()
        errorState.isHidden = true
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
              !isQueueVisible,
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
              !isQueueVisible,
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

    private func hideSeekIndicator() {
        hideSeekIndicatorTimer?.invalidate()
        hideSeekIndicatorTimer = nil
        guard !seekIndicator.isHidden else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
            seekIndicator.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.seekIndicator.alphaValue == 0 else { return }
                self.seekIndicator.isHidden = true
            }
        }
    }

    private var controlsContainsFirstResponder: Bool {
        guard let firstResponder = window?.firstResponder as? NSView else { return false }
        return firstResponder === controls || firstResponder.isDescendant(of: controls)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropOverlay(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropOverlay(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropOverlay.isHidden = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { dropOverlay.isHidden = true }
        switch dragPayload(from: sender) {
        case let .videos(urls):
            onOpenVideos?(urls)
            return true
        case let .subtitle(url):
            onAddSubtitle?(url)
            return true
        case let .invalid(message):
            onInvalidFileDrop?(message)
            return false
        }
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        dropOverlay.isHidden = true
    }

    private func updateDropOverlay(for sender: NSDraggingInfo) -> NSDragOperation {
        switch dragPayload(from: sender) {
        case let .videos(urls):
            let message = urls.count == 1
                ? "Drop video to open"
                : "Drop \(urls.count) videos to create a queue"
            dropOverlay.present(message: message, isValid: true)
            return .copy
        case .subtitle:
            dropOverlay.present(message: "Drop subtitle to add", isValid: true)
            return .copy
        case let .invalid(message):
            dropOverlay.present(message: message, isValid: false)
            return []
        }
    }

    private func dragPayload(from sender: NSDraggingInfo) -> DragPayload {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
        guard let urls, !urls.isEmpty else {
            return .invalid("Drop a video file to open")
        }

        if urls.count == 1,
           let url = urls.first,
           Self.subtitleExtensions.contains(url.pathExtension.lowercased()) {
            return latestState.canControlPlayback
                ? .subtitle(url)
                : .invalid("Open a video before adding subtitles")
        }

        guard urls.allSatisfy({ Self.videoExtensions.contains($0.pathExtension.lowercased()) }) else {
            return .invalid("This file type can’t be played")
        }
        return .videos(urls)
    }

    private func toggleQueue() {
        setQueueVisible(!isQueueVisible)
    }

    private func setQueueVisible(_ visible: Bool) {
        isQueueVisible = visible && latestState.hasQueue
        queueView.isHidden = !isQueueVisible
        if isQueueVisible {
            showControls(scheduleHide: false)
        }
    }
}

private enum DragPayload {
    case videos([URL])
    case subtitle(URL)
    case invalid(String)
}

private final class PlaybackFeedbackView: NSVisualEffectView {
    private let textLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.staticText)

        textLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        textLabel.textColor = .labelColor
        textLabel.alignment = .center
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textLabel)

        NSLayoutConstraint.activate([
            textLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            textLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            textLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            textLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 52)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(text: String) {
        textLabel.stringValue = text
        setAccessibilityLabel(text)
        isHidden = false
    }
}

private extension NSView {
    var hasActiveMenu: Bool {
        if let popUp = self as? NSPopUpButton, popUp.menu?.highlightedItem != nil { return true }
        return subviews.contains(where: \.hasActiveMenu)
    }
}
