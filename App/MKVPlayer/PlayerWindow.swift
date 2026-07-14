import AppKit

@MainActor
protocol PlayerWindowKeyboardDelegate: AnyObject {
    func playerWindowDidRequestControls()
    func playerWindowDidRequestTogglePlayback()
    func playerWindowDidRequestSeek(by offset: TimeInterval)
    func playerWindowDidBeginTemporaryFastPlayback()
    func playerWindowDidEndTemporaryFastPlayback()
    func playerWindowDidRequestEscape()
}

@MainActor
final class SpaceHoldShortcutController {
    private enum State: Equatable {
        case idle
        case waitingForHold
        case holding
    }

    var onQuickPress: (() -> Void)?
    var onHoldBegan: (() -> Void)?
    var onHoldEnded: (() -> Void)?

    private let holdDelay: TimeInterval
    private var state: State = .idle
    private var holdTimer: Timer?

    init(holdDelay: TimeInterval = 0.25) {
        self.holdDelay = holdDelay
    }

    func keyDown() {
        guard state == .idle else { return }
        state = .waitingForHold

        let timer = Timer(timeInterval: holdDelay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.beginHoldIfNeeded() }
        }
        holdTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @discardableResult
    func keyUp() -> Bool {
        switch state {
        case .idle:
            return false
        case .waitingForHold:
            resetTimer()
            state = .idle
            onQuickPress?()
            return true
        case .holding:
            resetTimer()
            state = .idle
            onHoldEnded?()
            return true
        }
    }

    /// Cancels without treating an interrupted key press as a play/pause command.
    func cancel() {
        let wasHolding = state == .holding
        resetTimer()
        state = .idle
        if wasHolding { onHoldEnded?() }
    }

    private func beginHoldIfNeeded() {
        guard state == .waitingForHold else { return }
        holdTimer = nil
        state = .holding
        onHoldBegan?()
    }

    private func resetTimer() {
        holdTimer?.invalidate()
        holdTimer = nil
    }
}

final class PlayerWindow: NSWindow {
    weak var playbackKeyboardDelegate: PlayerWindowKeyboardDelegate?
    private lazy var spaceShortcut = makeSpaceShortcut()

    static func routesPlaybackShortcuts(when firstResponder: NSResponder?) -> Bool {
        !(firstResponder is NSControl) && !(firstResponder is NSTextView)
    }

    static func playbackModifiers(from flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = Self.playbackModifiers(from: event.modifierFlags)
        let routesPlaybackShortcuts = Self.routesPlaybackShortcuts(when: firstResponder)

        if event.keyCode == 48, modifiers.isEmpty || modifiers == .shift {
            playbackKeyboardDelegate?.playerWindowDidRequestControls()
            super.keyDown(with: event)
            return
        }

        if modifiers.isEmpty {
            switch event.keyCode {
            case 49:
                guard routesPlaybackShortcuts else { break }
                // NSEvent sends repeated keyDown events while Space remains held.
                // The shortcut controller accepts only the initial transition.
                spaceShortcut.keyDown()
                return
            case 123:
                guard routesPlaybackShortcuts else { break }
                playbackKeyboardDelegate?.playerWindowDidRequestSeek(by: -5)
                return
            case 124:
                guard routesPlaybackShortcuts else { break }
                playbackKeyboardDelegate?.playerWindowDidRequestSeek(by: 5)
                return
            case 53:
                playbackKeyboardDelegate?.playerWindowDidRequestEscape()
                return
            default:
                break
            }
        }

        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49, spaceShortcut.keyUp() {
            return
        }
        super.keyUp(with: event)
    }

    override func resignKey() {
        spaceShortcut.cancel()
        super.resignKey()
    }

    override func close() {
        spaceShortcut.cancel()
        super.close()
    }

    private func makeSpaceShortcut() -> SpaceHoldShortcutController {
        let shortcut = SpaceHoldShortcutController()
        shortcut.onQuickPress = { [weak self] in
            self?.playbackKeyboardDelegate?.playerWindowDidRequestTogglePlayback()
        }
        shortcut.onHoldBegan = { [weak self] in
            self?.playbackKeyboardDelegate?.playerWindowDidBeginTemporaryFastPlayback()
        }
        shortcut.onHoldEnded = { [weak self] in
            self?.playbackKeyboardDelegate?.playerWindowDidEndTemporaryFastPlayback()
        }
        return shortcut
    }
}
