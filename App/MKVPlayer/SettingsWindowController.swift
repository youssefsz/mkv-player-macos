import AppKit
import Sparkle
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    init(updater: SPUUpdater) {
        let updateSettings = UpdateSettingsModel(updater: updater)
        let host = NSHostingController(rootView: SettingsView(updateSettings: updateSettings))
        let window = NSWindow(contentViewController: host)
        window.title = "Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
