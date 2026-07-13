import AppKit

@MainActor
protocol PlayerWindowKeyboardDelegate: AnyObject {
    func playerWindowDidRequestControls()
    func playerWindowDidRequestTogglePlayback()
    func playerWindowDidRequestSeek(by offset: TimeInterval)
    func playerWindowDidRequestEscape()
}

final class PlayerWindow: NSWindow {
    weak var playbackKeyboardDelegate: PlayerWindowKeyboardDelegate?

    static func routesPlaybackShortcuts(when firstResponder: NSResponder?) -> Bool {
        !(firstResponder is NSControl) && !(firstResponder is NSTextView)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad])
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
                playbackKeyboardDelegate?.playerWindowDidRequestTogglePlayback()
                return
            case 123:
                guard routesPlaybackShortcuts else { break }
                playbackKeyboardDelegate?.playerWindowDidRequestSeek(by: -10)
                return
            case 124:
                guard routesPlaybackShortcuts else { break }
                playbackKeyboardDelegate?.playerWindowDidRequestSeek(by: 10)
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
}
