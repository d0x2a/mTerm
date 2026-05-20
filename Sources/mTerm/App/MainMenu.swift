import AppKit

enum MainMenu {
    static func build() -> NSMenu {
        let mainMenu = NSMenu()
        let appName = ProcessInfo.processInfo.processName

        // Application menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(appName)",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        let settings = appMenu.addItem(withTitle: "Settings…",
                                       action: #selector(AppDelegate.showSettings(_:)),
                                       keyEquivalent: ",")
        settings.keyEquivalentModifierMask = [.command]
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide \(appName)",
                        action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)),
                                         keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)),
                        keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit \(appName)",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File menu
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Tab",
                         action: #selector(AppDelegate.openNewTab(_:)),
                         keyEquivalent: "t")
        fileMenu.addItem(withTitle: "Close Tab",
                         action: #selector(AppDelegate.closeActiveTab(_:)),
                         keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Edit menu
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Find",
                         action: #selector(TerminalView.performFind(_:)),
                         keyEquivalent: "f")
        editMenu.addItem(withTitle: "Find Next",
                         action: #selector(TerminalView.findNext(_:)),
                         keyEquivalent: "g")
        let findPrev = editMenu.addItem(
            withTitle: "Find Previous",
            action: #selector(TerminalView.findPrevious(_:)),
            keyEquivalent: "g"
        )
        findPrev.keyEquivalentModifierMask = [.command, .shift]
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // View menu
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let fullScreen = viewMenu.addItem(withTitle: "Enter Full Screen",
                                          action: #selector(NSWindow.toggleFullScreen(_:)),
                                          keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]

        viewMenu.addItem(NSMenuItem.separator())
        let prevPrompt = viewMenu.addItem(
            withTitle: "Jump to Previous Prompt",
            action: #selector(TerminalView.jumpToPreviousPrompt(_:)),
            keyEquivalent: "\u{F700}"           // NSUpArrowFunctionKey
        )
        prevPrompt.keyEquivalentModifierMask = [.command]
        let nextPrompt = viewMenu.addItem(
            withTitle: "Jump to Next Prompt",
            action: #selector(TerminalView.jumpToNextPrompt(_:)),
            keyEquivalent: "\u{F701}"           // NSDownArrowFunctionKey
        )
        nextPrompt.keyEquivalentModifierMask = [.command]

        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Window menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)),
                           keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom",
                           action: #selector(NSWindow.performZoom(_:)),
                           keyEquivalent: "")
        windowMenu.addItem(NSMenuItem.separator())

        let nextTab = windowMenu.addItem(withTitle: "Show Next Tab",
                                         action: #selector(AppDelegate.selectNextTab(_:)),
                                         keyEquivalent: "]")
        nextTab.keyEquivalentModifierMask = [.command, .shift]

        let prevTab = windowMenu.addItem(withTitle: "Show Previous Tab",
                                         action: #selector(AppDelegate.selectPreviousTab(_:)),
                                         keyEquivalent: "[")
        prevTab.keyEquivalentModifierMask = [.command, .shift]

        // ⌘` / ⌘⇧` are wired in AppDelegate via an NSEvent local monitor
        // (see `installTabCycleShortcut`). They're not menu items because
        // (1) hidden NSMenuItems don't fire their key equivalents, and
        // (2) macOS reserves ⌘` for "Move focus to next window of the
        // application" at the system level, which would intercept the
        // event before any visible menu shortcut.

        windowMenu.addItem(NSMenuItem.separator())

        for n in 1...9 {
            let title = (n == 9) ? "Show Last Tab" : "Show Tab \(n)"
            let item = windowMenu.addItem(
                withTitle: title,
                action: #selector(AppDelegate.selectTabByNumber(_:)),
                keyEquivalent: "\(n)"
            )
            item.tag = n
            item.keyEquivalentModifierMask = [.command]
        }

        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        return mainMenu
    }
}
