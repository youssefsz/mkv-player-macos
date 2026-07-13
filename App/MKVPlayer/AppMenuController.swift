import AppKit

@MainActor
final class AppMenuController: NSObject {
    private weak var commandTarget: AnyObject?
    private let openRecentMenu = NSMenu(title: "Open Recent")
    private let audioMenu = NSMenu(title: "Audio")
    private let subtitleMenu = NSMenu(title: "Subtitles")
    private let chapterMenu = NSMenu(title: "Chapters")
    // Raw transport keys are routed by PlayerWindow so focused native controls
    // keep their standard Space and arrow-key behavior.
    private let playPauseItem = NSMenuItem(title: "Play", action: #selector(AppDelegate.togglePlayback(_:)), keyEquivalent: "")
    private let fitItem = NSMenuItem(title: "Fit to Window", action: #selector(AppDelegate.fitVideo(_:)), keyEquivalent: "")
    private let fillItem = NSMenuItem(title: "Fill Window", action: #selector(AppDelegate.fillVideo(_:)), keyEquivalent: "")
    private let actualSizeItem = NSMenuItem(title: "Actual Size", action: #selector(AppDelegate.showVideoAtActualSize(_:)), keyEquivalent: "1")
    private let fullScreenItem = NSMenuItem(title: "Enter Full Screen", action: #selector(AppDelegate.toggleFullScreen(_:)), keyEquivalent: "f")
    private var speedItems: [NSMenuItem] = []
    private var cachedRecentURLs: [URL]?
    private var cachedAudioTracks: [PlayerTrackOption]?
    private var cachedSubtitleTracks: [PlayerTrackOption]?
    private var cachedSubtitleAvailability: Bool?
    private var cachedChapters: [PlayerChapterOption]?
    private(set) var contentRevision = 0

    init(commandTarget: AnyObject) {
        self.commandTarget = commandTarget
        super.init()
        NSApp.mainMenu = buildMainMenu()
    }

    func refresh(state: PlayerPresentationState, recentURLs: [URL]) {
        playPauseItem.title = state.isPlaying ? "Pause" : "Play"
        fitItem.state = state.videoScaling == .fit ? .on : .off
        fillItem.state = state.videoScaling == .fill ? .on : .off
        actualSizeItem.state = state.videoScaling == .actualSize ? .on : .off
        fullScreenItem.title = state.isFullScreen ? "Exit Full Screen" : "Enter Full Screen"

        if cachedRecentURLs != recentURLs {
            cachedRecentURLs = recentURLs
            rebuildRecentMenu(recentURLs)
        }
        if cachedAudioTracks != state.audioTracks {
            cachedAudioTracks = state.audioTracks
            rebuildAudioMenu(state.audioTracks)
        }
        if cachedSubtitleTracks != state.subtitleTracks
            || cachedSubtitleAvailability != state.canControlPlayback {
            cachedSubtitleTracks = state.subtitleTracks
            cachedSubtitleAvailability = state.canControlPlayback
            rebuildSubtitleMenu(
                state.subtitleTracks,
                canAddSubtitle: state.canControlPlayback
            )
        }
        if cachedChapters != state.chapters {
            cachedChapters = state.chapters
            rebuildChapterMenu(state.chapters)
        }
        speedItems.forEach { item in
            guard let rate = item.representedObject as? Double else { return }
            item.state = abs(rate - state.rate) < 0.001 ? .on : .off
            item.isEnabled = state.canControlPlayback
        }
    }

    private func buildMainMenu() -> NSMenu {
        let main = NSMenu(title: "Main Menu")
        main.addItem(applicationMenuItem())
        main.addItem(fileMenuItem())
        main.addItem(playbackMenuItem())
        main.addItem(menuItem(title: "Audio", submenu: audioMenu))
        main.addItem(menuItem(title: "Subtitles", submenu: subtitleMenu))
        main.addItem(viewMenuItem())
        main.addItem(windowMenuItem())
        main.addItem(helpMenuItem())
        return main
    }

    private func applicationMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "MKV Player")
        let about = item("About MKV Player", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        about.target = NSApp
        menu.addItem(about)
        menu.addItem(.separator())
        menu.addItem(item("Check for Updates…", #selector(AppDelegate.checkForUpdates(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(AppDelegate.showSettings(_:)), key: ","))
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        NSApp.servicesMenu = services
        menu.addItem(menuItem(title: "Services", submenu: services))
        menu.addItem(.separator())
        let hide = item("Hide MKV Player", #selector(NSApplication.hide(_:)), key: "h")
        hide.target = NSApp
        menu.addItem(hide)
        let hideOthers = item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), key: "h", modifiers: [.command, .option])
        hideOthers.target = NSApp
        menu.addItem(hideOthers)
        let showAll = item("Show All", #selector(NSApplication.unhideAllApplications(_:)))
        showAll.target = NSApp
        menu.addItem(showAll)
        menu.addItem(.separator())
        let quit = item("Quit MKV Player", #selector(NSApplication.terminate(_:)), key: "q")
        quit.target = NSApp
        menu.addItem(quit)
        return menuItem(title: "MKV Player", submenu: menu)
    }

    private func fileMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "File")
        menu.addItem(item("Open…", #selector(AppDelegate.openVideo(_:)), key: "o"))
        menu.addItem(menuItem(title: "Open Recent", submenu: openRecentMenu))
        menu.addItem(item("Add Subtitle File…", #selector(AppDelegate.addSubtitle(_:)), key: "s", modifiers: [.command, .shift]))
        menu.addItem(.separator())
        let close = item("Close", #selector(NSWindow.performClose(_:)), key: "w")
        close.target = nil
        menu.addItem(close)
        return menuItem(title: "File", submenu: menu)
    }

    private func playbackMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Playback")
        playPauseItem.target = commandTarget
        menu.addItem(playPauseItem)
        menu.addItem(.separator())
        menu.addItem(item("Back 10 Seconds", #selector(AppDelegate.seekBackward(_:))))
        menu.addItem(item("Forward 10 Seconds", #selector(AppDelegate.seekForward(_:))))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Chapters", submenu: chapterMenu))

        let speedMenu = NSMenu(title: "Playback Speed")
        for rate in [0.5, 0.75, 1.0, 1.25, 1.5, 2.0] {
            let label = rate == 1 ? "Normal" : "\(rate.formatted())×"
            let speedItem = item(label, #selector(AppDelegate.setPlaybackRate(_:)))
            speedItem.representedObject = rate
            speedMenu.addItem(speedItem)
            speedItems.append(speedItem)
        }
        menu.addItem(menuItem(title: "Playback Speed", submenu: speedMenu))
        return menuItem(title: "Playback", submenu: menu)
    }

    private func viewMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "View")
        for item in [fitItem, fillItem, actualSizeItem] {
            item.target = commandTarget
        }
        actualSizeItem.keyEquivalentModifierMask = [.command]
        menu.addItem(fitItem)
        menu.addItem(fillItem)
        menu.addItem(actualSizeItem)
        menu.addItem(.separator())
        fullScreenItem.target = commandTarget
        fullScreenItem.keyEquivalentModifierMask = [.control, .command]
        menu.addItem(fullScreenItem)
        return menuItem(title: "View", submenu: menu)
    }

    private func windowMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Window")
        let minimize = item("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m")
        minimize.target = nil
        menu.addItem(minimize)
        let zoom = item("Zoom", #selector(NSWindow.performZoom(_:)))
        zoom.target = nil
        menu.addItem(zoom)
        menu.addItem(.separator())
        let bringAllToFront = item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        bringAllToFront.target = NSApp
        menu.addItem(bringAllToFront)
        NSApp.windowsMenu = menu
        return menuItem(title: "Window", submenu: menu)
    }

    private func helpMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Help")
        menu.addItem(item("MKV Player on GitHub", #selector(AppDelegate.openProjectWebsite(_:))))
        menu.addItem(item("Report an Issue…", #selector(AppDelegate.reportIssue(_:))))
        NSApp.helpMenu = menu
        return menuItem(title: "Help", submenu: menu)
    }

    private func rebuildRecentMenu(_ urls: [URL]) {
        contentRevision &+= 1
        openRecentMenu.removeAllItems()
        if urls.isEmpty {
            let empty = NSMenuItem(title: "No Recent Videos", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            openRecentMenu.addItem(empty)
        } else {
            for url in urls.prefix(10) {
                let recent = item(url.lastPathComponent, #selector(AppDelegate.openRecent(_:)))
                recent.representedObject = url
                recent.toolTip = url.path
                openRecentMenu.addItem(recent)
            }
            openRecentMenu.addItem(.separator())
            openRecentMenu.addItem(item("Clear Menu", #selector(AppDelegate.clearRecent(_:))))
        }
    }

    private func rebuildAudioMenu(_ tracks: [PlayerTrackOption]) {
        contentRevision &+= 1
        audioMenu.removeAllItems()
        guard !tracks.isEmpty else {
            audioMenu.addItem(disabledItem("No Audio Tracks"))
            return
        }
        for track in tracks {
            let menuItem = item(track.title, #selector(AppDelegate.selectAudioTrack(_:)))
            menuItem.representedObject = track.id
            menuItem.state = track.isSelected ? .on : .off
            menuItem.toolTip = track.detail
            audioMenu.addItem(menuItem)
        }
    }

    private func rebuildSubtitleMenu(_ tracks: [PlayerTrackOption], canAddSubtitle: Bool) {
        contentRevision &+= 1
        subtitleMenu.removeAllItems()
        let off = item("Off", #selector(AppDelegate.disableSubtitles(_:)))
        off.state = tracks.contains(where: \.isSelected) ? .off : .on
        off.isEnabled = canAddSubtitle
        subtitleMenu.addItem(off)
        if !tracks.isEmpty { subtitleMenu.addItem(.separator()) }
        for track in tracks {
            let menuItem = item(track.title, #selector(AppDelegate.selectSubtitleTrack(_:)))
            menuItem.representedObject = track.id
            menuItem.state = track.isSelected ? .on : .off
            menuItem.toolTip = track.detail
            subtitleMenu.addItem(menuItem)
        }
        subtitleMenu.addItem(.separator())
        let add = item("Add Subtitle File…", #selector(AppDelegate.addSubtitle(_:)))
        add.isEnabled = canAddSubtitle
        subtitleMenu.addItem(add)
    }

    private func rebuildChapterMenu(_ chapters: [PlayerChapterOption]) {
        contentRevision &+= 1
        chapterMenu.removeAllItems()
        guard !chapters.isEmpty else {
            chapterMenu.addItem(disabledItem("No Chapters"))
            return
        }
        for chapter in chapters {
            let label = "\(TimeText.format(chapter.time))  \(chapter.title)"
            let menuItem = item(label, #selector(AppDelegate.selectChapter(_:)))
            menuItem.representedObject = chapter.index
            menuItem.state = chapter.isSelected ? .on : .off
            chapterMenu.addItem(menuItem)
        }
    }

    private func item(
        _ title: String,
        _ action: Selector?,
        key: String = "",
        modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = commandTarget
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        return item
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func menuItem(title: String, submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }
}
