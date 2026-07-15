import AppKit

final class PlaybackControlsView: NSVisualEffectView {
    var onOpenVideo: (() -> Void)?
    var onToggleQueue: (() -> Void)?
    var onTogglePlayback: (() -> Void)?
    var onSeekRelative: ((TimeInterval) -> Void)?
    var onSeekAbsolute: ((TimeInterval) -> Void)?
    var onSeekPreview: ((TimeInterval) -> Void)?
    var onScrubbingChanged: ((Bool) -> Void)?
    var onVolumeChanged: ((Double) -> Void)?
    var onPlaybackRateChanged: ((Double) -> Void)?
    var onToggleMute: (() -> Void)?
    var onAudioTrackSelected: ((Int64) -> Void)?
    var onSubtitleTrackSelected: ((Int64?) -> Void)?
    var onChapterSelected: ((Int) -> Void)?
    var onToggleFullScreen: (() -> Void)?

    private let seekSlider = TrackingSlider(value: 0, minValue: 0, maxValue: 1)
    private let elapsedLabel = NSTextField(labelWithString: "0:00")
    private let remainingLabel = NSTextField(labelWithString: "–0:00")
    private let openButton = ActionButton(
        symbolName: "folder",
        accessibilityLabel: "Open Video",
        toolTip: "Open Video… (Command-O)"
    )
    private let backButton = ActionButton(symbolName: "gobackward.10", accessibilityLabel: "Back 10 seconds", toolTip: "Back 10 Seconds")
    private let playButton = ActionButton(symbolName: "play.fill", accessibilityLabel: "Play", toolTip: "Play or Pause")
    private let forwardButton = ActionButton(symbolName: "goforward.10", accessibilityLabel: "Forward 10 seconds", toolTip: "Forward 10 Seconds")
    private let muteButton = ActionButton(symbolName: "speaker.wave.2.fill", accessibilityLabel: "Mute", toolTip: "Mute")
    private let volumeSlider = NSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let audioButton = ActionPopUpButton(frame: .zero, pullsDown: false)
    private let subtitleButton = ActionPopUpButton(frame: .zero, pullsDown: false)
    private let chapterButton = ActionPopUpButton(frame: .zero, pullsDown: false)
    private let speedButton = ActionPopUpButton(frame: .zero, pullsDown: false)
    private let fullScreenButton = ActionButton(
        symbolName: "arrow.up.left.and.arrow.down.right",
        accessibilityLabel: "Enter Full Screen",
        toolTip: "Enter Full Screen"
    )
    private let queueButton = ActionButton(
        symbolName: "list.bullet",
        accessibilityLabel: "Show Queue",
        toolTip: "Show Queue"
    )

    private var playbackState = PlayerPresentationState()
    private var isScrubbing = false
    private var didBuildTrackMenus = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.group)
        setAccessibilityLabel("Playback controls")

        seekSlider.translatesAutoresizingMaskIntoConstraints = false
        seekSlider.setAccessibilityLabel("Playback position")
        seekSlider.valueChanged = { [weak self] value in
            guard let self else { return }
            self.elapsedLabel.stringValue = TimeText.format(value)
            self.onSeekPreview?(value)
        }
        seekSlider.trackingChanged = { [weak self] tracking in
            self?.isScrubbing = tracking
            self?.onScrubbingChanged?(tracking)
        }
        seekSlider.committed = { [weak self] value in self?.onSeekAbsolute?(value) }

        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        elapsedLabel.textColor = .secondaryLabelColor
        remainingLabel.font = elapsedLabel.font
        remainingLabel.textColor = .secondaryLabelColor
        remainingLabel.alignment = .right

        let timeRow = NSStackView(views: [elapsedLabel, NSView(), remainingLabel])
        timeRow.orientation = .horizontal
        timeRow.distribution = .fill
        timeRow.translatesAutoresizingMaskIntoConstraints = false

        openButton.handler = { [weak self] in self?.onOpenVideo?() }
        queueButton.handler = { [weak self] in self?.onToggleQueue?() }
        backButton.handler = { [weak self] in self?.onSeekRelative?(-10) }
        playButton.handler = { [weak self] in self?.onTogglePlayback?() }
        forwardButton.handler = { [weak self] in self?.onSeekRelative?(10) }
        muteButton.handler = { [weak self] in self?.onToggleMute?() }
        fullScreenButton.handler = { [weak self] in self?.onToggleFullScreen?() }

        volumeSlider.translatesAutoresizingMaskIntoConstraints = false
        volumeSlider.isContinuous = true
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged)
        volumeSlider.setAccessibilityLabel("Volume")
        volumeSlider.widthAnchor.constraint(equalToConstant: 84).isActive = true

        configurePopUps()

        let transport = NSStackView(views: [
            openButton,
            chapterButton,
            audioButton,
            subtitleButton,
            NSView(),
            backButton,
            playButton,
            forwardButton,
            NSView(),
            muteButton,
            volumeSlider,
            speedButton,
            queueButton,
            fullScreenButton
        ])
        transport.orientation = .horizontal
        transport.alignment = .centerY
        transport.spacing = 7
        transport.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView(views: [seekSlider, timeRow, transport])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 5
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            seekSlider.widthAnchor.constraint(equalTo: content.widthAnchor),
            timeRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            transport.widthAnchor.constraint(equalTo: content.widthAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 500),
            widthAnchor.constraint(lessThanOrEqualToConstant: 760)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(_ newState: PlayerPresentationState) {
        let trackMenusChanged = !didBuildTrackMenus
            || playbackState.chapters != newState.chapters
            || playbackState.audioTracks != newState.audioTracks
            || playbackState.subtitleTracks != newState.subtitleTracks
        playbackState = newState
        queueButton.isHidden = !newState.hasQueue
        queueButton.setAccessibilityLabel("Show Queue, \(newState.queueItems.count) videos")
        queueButton.toolTip = "Show Queue (\(newState.queueItems.count))"
        if !isScrubbing {
            seekSlider.maxValue = max(newState.duration, 1)
            seekSlider.doubleValue = min(max(newState.position, 0), seekSlider.maxValue)
            elapsedLabel.stringValue = TimeText.format(newState.position)
        }
        seekSlider.isEnabled = newState.canSeek
        backButton.isEnabled = newState.canSeek
        forwardButton.isEnabled = newState.canSeek
        remainingLabel.stringValue = newState.canSeek ? "–\(TimeText.format(max(0, newState.duration - newState.position)))" : "–:––"

        let playSymbol = newState.isPlaying ? "pause.fill" : "play.fill"
        let playLabel = newState.isPlaying ? "Pause" : "Play"
        playButton.image = NSImage(systemSymbolName: playSymbol, accessibilityDescription: playLabel)
        playButton.setAccessibilityLabel(playLabel)
        playButton.isEnabled = newState.canControlPlayback

        volumeSlider.doubleValue = newState.volume
        volumeSlider.isEnabled = newState.canControlPlayback
        let muteSymbol = newState.isMuted || newState.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill"
        muteButton.image = NSImage(systemSymbolName: muteSymbol, accessibilityDescription: newState.isMuted ? "Unmute" : "Mute")
        muteButton.setAccessibilityLabel(newState.isMuted ? "Unmute" : "Mute")
        muteButton.isEnabled = newState.canControlPlayback

        let fullScreenLabel = newState.isFullScreen ? "Exit Full Screen" : "Enter Full Screen"
        let fullScreenSymbol = newState.isFullScreen
            ? "arrow.down.right.and.arrow.up.left"
            : "arrow.up.left.and.arrow.down.right"
        fullScreenButton.image = NSImage(
            systemSymbolName: fullScreenSymbol,
            accessibilityDescription: fullScreenLabel
        )
        fullScreenButton.setAccessibilityLabel(fullScreenLabel)
        fullScreenButton.toolTip = fullScreenLabel

        chapterButton.isEnabled = newState.canControlPlayback && !newState.chapters.isEmpty
        audioButton.isEnabled = newState.canControlPlayback && !newState.audioTracks.isEmpty
        subtitleButton.isEnabled = newState.canControlPlayback && !newState.subtitleTracks.isEmpty
        speedButton.isEnabled = newState.canControlPlayback
        if let selectedRateIndex = PlaybackRateOptions.all.firstIndex(where: {
            abs($0 - newState.rate) < 0.001
        }) {
            speedButton.selectItem(at: selectedRateIndex)
        }

        if trackMenusChanged {
            rebuildTrackMenus(newState)
            didBuildTrackMenus = true
        }
    }

    private func configurePopUps() {
        chapterButton.toolTip = "Chapters"
        chapterButton.setAccessibilityLabel("Chapters")
        audioButton.toolTip = "Audio Track"
        audioButton.setAccessibilityLabel("Audio Track")
        subtitleButton.toolTip = "Subtitles"
        subtitleButton.setAccessibilityLabel("Subtitles")
        speedButton.toolTip = "Playback Speed"
        speedButton.setAccessibilityLabel("Playback speed")
        speedButton.addItems(withTitles: PlaybackRateOptions.all.map(PlaybackRateOptions.label))
        speedButton.selectItem(at: PlaybackRateOptions.all.firstIndex(of: 1) ?? 0)
        speedButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 58).isActive = true

        chapterButton.selectionHandler = { [weak self] index in
            guard let self, self.playbackState.chapters.indices.contains(index) else { return }
            self.onChapterSelected?(self.playbackState.chapters[index].index)
        }
        audioButton.selectionHandler = { [weak self] index in
            guard let self, self.playbackState.audioTracks.indices.contains(index) else { return }
            self.onAudioTrackSelected?(self.playbackState.audioTracks[index].id)
        }
        subtitleButton.selectionHandler = { [weak self] index in
            guard let self else { return }
            if index == 0 { self.onSubtitleTrackSelected?(nil); return }
            let trackIndex = index - 1
            guard self.playbackState.subtitleTracks.indices.contains(trackIndex) else { return }
            self.onSubtitleTrackSelected?(self.playbackState.subtitleTracks[trackIndex].id)
        }
        speedButton.selectionHandler = { [weak self] index in
            guard PlaybackRateOptions.all.indices.contains(index) else { return }
            self?.onPlaybackRateChanged?(PlaybackRateOptions.all[index])
        }
    }

    private func rebuildTrackMenus(_ state: PlayerPresentationState) {
        chapterButton.removeAllItems()
        chapterButton.addItems(withTitles: state.chapters.isEmpty ? ["Chapters"] : state.chapters.map(\.title))
        if let selected = state.chapters.firstIndex(where: \.isSelected) { chapterButton.selectItem(at: selected) }

        audioButton.removeAllItems()
        audioButton.addItems(withTitles: state.audioTracks.isEmpty ? ["Audio"] : state.audioTracks.map(\.title))
        if let selected = state.audioTracks.firstIndex(where: \.isSelected) { audioButton.selectItem(at: selected) }

        subtitleButton.removeAllItems()
        subtitleButton.addItem(withTitle: "Subtitles Off")
        subtitleButton.addItems(withTitles: state.subtitleTracks.map(\.title))
        if let selected = state.subtitleTracks.firstIndex(where: \.isSelected) {
            subtitleButton.selectItem(at: selected + 1)
        } else {
            subtitleButton.selectItem(at: 0)
        }
    }

    @objc private func volumeChanged() {
        onVolumeChanged?(volumeSlider.doubleValue)
    }
}
