import AppKit

@MainActor
protocol PlayerViewControllerDelegate: AnyObject {
    func playerViewControllerDidRequestOpenPanel(_ controller: PlayerViewController)
    func playerViewController(_ controller: PlayerViewController, didOpen urls: [URL])
    func playerViewController(_ controller: PlayerViewController, didAddSubtitle url: URL)
    func playerViewController(_ controller: PlayerViewController, didRejectDrop message: String)
    func playerViewControllerDidRequestTogglePlayback(_ controller: PlayerViewController)
    func playerViewController(_ controller: PlayerViewController, didRequestRelativeSeek offset: TimeInterval)
    func playerViewControllerDidBeginScrubbing(_ controller: PlayerViewController)
    func playerViewController(_ controller: PlayerViewController, didUpdateScrubbing position: TimeInterval)
    func playerViewControllerDidCommitScrubbing(_ controller: PlayerViewController)
    func playerViewController(_ controller: PlayerViewController, didChangeVolume volume: Double)
    func playerViewControllerDidRequestToggleMute(_ controller: PlayerViewController)
    func playerViewController(_ controller: PlayerViewController, didChangePlaybackRate rate: Double)
    func playerViewController(_ controller: PlayerViewController, didSelectAudioTrack id: Int64)
    func playerViewController(_ controller: PlayerViewController, didSelectSubtitleTrack id: Int64?)
    func playerViewController(_ controller: PlayerViewController, didSelectChapter index: Int)
    func playerViewControllerDidRequestFullScreen(_ controller: PlayerViewController)
    func playerViewControllerDidRequestRestart(_ controller: PlayerViewController)
    func playerViewControllerDidRequestReplay(_ controller: PlayerViewController)
    func playerViewController(_ controller: PlayerViewController, didSelectQueueItem id: UUID)
    func playerViewController(_ controller: PlayerViewController, didRemoveQueueItem id: UUID)
    func playerViewControllerDidRequestPreviousQueueItem(_ controller: PlayerViewController)
    func playerViewControllerDidRequestNextQueueItem(_ controller: PlayerViewController)
    func playerViewControllerDidDismissRecoverableError(_ controller: PlayerViewController)
}

final class PlayerViewController: NSViewController {
    weak var delegate: PlayerViewControllerDelegate?

    private let canvas = PlayerCanvasView(frame: .zero)
    private(set) var presentationState = PlayerPresentationState()

    override func loadView() {
        view = canvas
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        wireActions()
    }

    func installVideoView(_ videoView: NSView) {
        canvas.installVideoView(videoView)
    }

    func render(_ state: PlayerPresentationState) {
        presentationState = state
        canvas.render(state)
    }

    func showResume(position: TimeInterval) {
        canvas.showResume(position: position)
    }

    func hideResume() {
        canvas.hideResume()
    }

    func showControls() {
        canvas.showControls(scheduleHide: true)
    }

    func setTemporaryFastPlaybackActive(_ isActive: Bool) {
        canvas.setTemporaryFastPlaybackActive(isActive)
    }

    func showKeyboardSeekFeedback(offset: TimeInterval) {
        canvas.showKeyboardSeekFeedback(offset: offset)
    }

    func prepareForMediaReplacement() {
        canvas.prepareForMediaReplacement()
    }

    private func wireActions() {
        canvas.onOpenPanel = { [weak self] in
            guard let self else { return }
            self.delegate?.playerViewControllerDidRequestOpenPanel(self)
        }
        canvas.onOpenVideos = { [weak self] urls in
            guard let self else { return }
            self.delegate?.playerViewController(self, didOpen: urls)
        }
        canvas.onAddSubtitle = { [weak self] url in
            guard let self else { return }
            self.delegate?.playerViewController(self, didAddSubtitle: url)
        }
        canvas.onInvalidFileDrop = { [weak self] message in
            guard let self else { return }
            self.delegate?.playerViewController(self, didRejectDrop: message)
        }
        canvas.onChooseAnother = { [weak self] in
            guard let self else { return }
            self.delegate?.playerViewControllerDidRequestOpenPanel(self)
        }
        canvas.onCopyDiagnostics = { [weak self] in self?.copyDiagnostics() }
        canvas.onDismissRecoverableError = { [weak self] in
            guard let self else { return }
            self.delegate?.playerViewControllerDidDismissRecoverableError(self)
        }
        canvas.onReplay = { [weak self] in
            guard let self else { return }
            self.delegate?.playerViewControllerDidRequestReplay(self)
        }
        canvas.onSelectQueueItem = { [weak self] id in
            guard let self else { return }
            self.delegate?.playerViewController(self, didSelectQueueItem: id)
        }
        canvas.onRemoveQueueItem = { [weak self] id in
            guard let self else { return }
            self.delegate?.playerViewController(self, didRemoveQueueItem: id)
        }
        canvas.onPreviousQueueItem = { [weak self] in
            guard let self else { return }
            self.delegate?.playerViewControllerDidRequestPreviousQueueItem(self)
        }
        canvas.onNextQueueItem = { [weak self] in
            guard let self else { return }
            self.delegate?.playerViewControllerDidRequestNextQueueItem(self)
        }
        canvas.controls.onTogglePlayback = { [weak self] in
            guard let self else { return }
            self.delegate?.playerViewControllerDidRequestTogglePlayback(self)
        }
        canvas.controls.onSeekRelative = { [weak self] offset in
            guard let self else { return }
            self.delegate?.playerViewController(self, didRequestRelativeSeek: offset)
        }
        canvas.controls.onSeekAbsolute = { [weak self] _ in
            guard let self else { return }
            self.delegate?.playerViewControllerDidCommitScrubbing(self)
        }
        canvas.controls.onSeekPreview = { [weak self] position in
            guard let self else { return }
            self.delegate?.playerViewController(self, didUpdateScrubbing: position)
        }
        canvas.onScrubbingChanged = { [weak self] isScrubbing in
            guard let self, isScrubbing else { return }
            self.delegate?.playerViewControllerDidBeginScrubbing(self)
        }
        canvas.controls.onVolumeChanged = { [weak self] volume in
            guard let self else { return }
            self.delegate?.playerViewController(self, didChangeVolume: volume)
        }
        canvas.controls.onToggleMute = { [weak self] in
            guard let self else { return }
            self.delegate?.playerViewControllerDidRequestToggleMute(self)
        }
        canvas.controls.onPlaybackRateChanged = { [weak self] rate in
            guard let self else { return }
            self.delegate?.playerViewController(self, didChangePlaybackRate: rate)
        }
        canvas.controls.onAudioTrackSelected = { [weak self] id in
            guard let self else { return }
            self.delegate?.playerViewController(self, didSelectAudioTrack: id)
        }
        canvas.controls.onSubtitleTrackSelected = { [weak self] id in
            guard let self else { return }
            self.delegate?.playerViewController(self, didSelectSubtitleTrack: id)
        }
        canvas.controls.onChapterSelected = { [weak self] index in
            guard let self else { return }
            self.delegate?.playerViewController(self, didSelectChapter: index)
        }
        canvas.controls.onToggleFullScreen = { [weak self] in
            guard let self else { return }
            self.delegate?.playerViewControllerDidRequestFullScreen(self)
        }
        canvas.resumeBanner.onRestart = { [weak self] in
            guard let self else { return }
            self.delegate?.playerViewControllerDidRequestRestart(self)
        }
    }

    private func copyDiagnostics() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(presentationState.diagnostics ?? "No diagnostics are available.", forType: .string)
    }
}
