#if canImport(AppKit)
import AppKit
import ServiceManagement

// A text field takes ⌘A, ⌘C, ⌘V and ⌘X from the Edit menu, and TheeJ has no menus in the menu bar, so
// its windows match those keys themselves. By the typed letter, or on a layout that types no Latin
// letter, by the key where A, C, V and X sit, as the menus do.
final class EditingWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let byLetter: [String: Selector] = ["a": #selector(NSText.selectAll(_:)), "c": #selector(NSText.copy(_:)),
                                            "v": #selector(NSText.paste(_:)), "x": #selector(NSText.cut(_:))]
        let byKey: [UInt16: String] = [0: "a", 8: "c", 9: "v", 7: "x"]
        let typed = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let letter = typed.allSatisfy(\.isASCII) ? typed : byKey[event.keyCode] ?? ""
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, let action = byLetter[letter],
           NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

final class MenuBar: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate, NSTextFieldDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    // An update check or install is running. About's Check for updates… goes off with it, and stays off
    // while an installed update waits for Reopen.
    var checking = false {
        didSet { checkButton?.isEnabled = !checking && UpdateProgress.underway == nil }
    }
    weak var checkButton: NSButton?
    var settingsWindow: NSWindow?
    var tabs: [NSToolbarItem.Identifier: NSView] = [:]  // Settings' pages, kept while another is shown
    var draft = Setup()
    let profilePicker = NSPopUpButton()
    let profileEdit = NSSegmentedControl()
    let profileName = NSTextField(string: "")
    // The shortcut of the profile shown in General, Next and Previous profile, then every profile's in
    // App settings. Each has a button that records it and a ✕, which shortcutRow makes in this order.
    var shortcutPaths: [WritableKeyPath<Setup, Shortcut?>] {
        [\Setup.profiles[draft.active].shortcut, \Setup.next, \Setup.previous]
            + draft.profiles.indices.map { \Setup.profiles[$0].shortcut }
    }
    var shortcutButtons: [NSButton] = []
    var removeShortcutButtons: [NSButton] = []
    var recorder: Any?  // the key monitor while a shortcut is being recorded
    var recording = 0  // which of shortcutPaths it records
    let profileRows = NSStackView()
    let profileShortcutRows = NSStackView()
    let knobRows = NSStackView()
    let knobEdit = NSSegmentedControl()
    let invertKnobs = NSSwitch()
    let showName = NSSwitch()
    let hideIcon = NSSwitch()
    let showNameLabel = NSTextField(labelWithString: "")  // these three are dimmed with the icon hidden
    let showProfiles = NSSwitch()
    let profileListLabel = NSTextField(labelWithString: "")
    let iconPicker = NSPopUpButton()
    let iconLabel = NSTextField(labelWithString: "")
    let speedPicker = NSPopUpButton()
    let languagePicker = NSPopUpButton()
    let m1ddcStatus = NSTextField(labelWithString: "")
    let m1ddcButton = NSButton(title: "", target: nil, action: nil)
    var m1ddcSupport = NSStackView()
    var m1ddcInstallStarted = false  // the button checks again instead of installing
    var calibrationWindow: NSWindow?
    var calibrator: Calibrator?
    var calibrationOffered = false
    let stepTitle = NSTextField(labelWithString: "")
    let stepBody = NSTextField(wrappingLabelWithString: "")
    let stepProgress = NSTextField(labelWithString: "")
    let skipButton = NSButton(title: "", target: nil, action: nil)
    let cancelButton = NSButton(title: "", target: nil, action: #selector(NSWindow.performClose(_:)))

    override init() {
        super.init()
        prefs.register(defaults: ["updateEvery": 604800, "showDataInMenu": true])
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        menuNeedsUpdate(menu)
        item.menu = menu  // assigned permanently, so left and right click both open it
        item.button?.imagePosition = .imageLeading
        refresh()

        let updates = Timer(timeInterval: 3600, target: self, selector: #selector(autoCheck), userInfo: nil, repeats: true)
        updates.tolerance = 600
        RunLoop.main.add(updates, forMode: .common)
        autoCheck()
    }

    func entry(_ title: String, _ action: Selector, _ key: String, symbol: String? = nil) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = self
        mi.isEnabled = true
        mi.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        return mi
    }

    // Rebuilt as the menu opens, so the status lines are never stale.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let state = shared.snapshot()
        let setup = shared.config().setup
        menu.removeAllItems()
        func label(_ text: String) -> NSMenuItem {
            let mi = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            mi.isEnabled = false
            return mi
        }
        let showData = prefs.bool(forKey: "showDataInMenu")
        let data = entry(tr("show_data"), #selector(toggleData), "")
        data.state = showData ? .on : .off
        menu.addItem(data)
        if showData, state.connected {
            // An app's line has its icon. Once one does, the others get a blank, to keep their text in line.
            let icons = state.lines.map { menuIcon($0.target) }
            let blank = icons.contains { $0 != nil } ? NSImage(size: NSSize(width: 16, height: 16)) : nil
            for (line, icon) in zip(state.lines, icons) {
                let item = label(line.text)
                item.image = icon ?? blank
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        if setup.showProfiles {
            menu.addItem(.sectionHeader(title: tr("profiles")))
            for (index, profile) in setup.profiles.enumerated() {
                let mi = entry(clipped(profile.name, to: 30), #selector(pickProfile), profile.shortcut?.key ?? "")
                mi.keyEquivalentModifierMask = profile.shortcut?.flags ?? []
                mi.tag = index
                mi.state = index == setup.active ? .on : .off
                menu.addItem(mi)
            }
            menu.addItem(.separator())
        }
        menu.addItem(entry(tr("settings"), #selector(openSettings), ","))
        let calibrateItem = entry(tr("calibrate"), #selector(calibrate), "", symbol: "wrench.and.screwdriver")
        calibrateItem.isEnabled = state.connected
        menu.addItem(calibrateItem)
        // The globe is the website's language picker. Each language is named in itself, so it can always be found.
        let languages = NSMenu()
        for (index, language) in Language.allCases.enumerated() {
            let choice = entry("\(language.flag) \(language.name)", #selector(pickLanguage), "")
            choice.tag = index
            choice.state = language == .current ? .on : .off
            languages.addItem(choice)
        }
        let languageItem = NSMenuItem(title: tr("language"), action: nil, keyEquivalent: "")
        languageItem.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        languageItem.submenu = languages
        menu.addItem(languageItem)
        menu.addItem(.separator())
        menu.addItem(label(state.connected ? tr("connected", ["port": state.port ?? "?"]) : tr("not_connected")))
        menu.addItem(entry(tr("reconnect"), #selector(reconnect), ""))
        menu.addItem(.separator())
        // Registering from anywhere else (a build folder) would point the login item at a bundle that disappears.
        let login = entry(tr("login"), #selector(toggleLogin), "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.isEnabled = Bundle.main.bundlePath.hasPrefix("/Applications/")
        menu.addItem(login)
        let dock = entry(tr("dock"), #selector(toggleDock), "")
        dock.state = inDock() ? .on : .off
        menu.addItem(dock)
        menu.addItem(.separator())
        menu.addItem(entry(tr("about"), #selector(about), "", symbol: "info.circle"))
        menu.addItem(.separator())
        // While an update installs, and until Reopen, its step stands in, in plain text that greys out:
        // the bold "Update available!" still looked clickable.
        let check = entry(UpdateProgress.underway ?? tr("check"), #selector(checkNow), "", symbol: "arrow.down.circle")
        check.isEnabled = !checking && UpdateProgress.underway == nil
        if let version = availableUpdate(), UpdateProgress.underway == nil {
            check.attributedTitle = updateAvailableTitle(version)
            check.image = updateAvailableIcon()
        }
        menu.addItem(check)
        let every = NSMenu()
        for (seconds, title) in [(86400, tr("daily")), (604800, tr("weekly")), (0, tr("never"))] {
            let choice = entry(title, #selector(pickUpdateEvery), "")
            choice.tag = seconds
            choice.state = prefs.integer(forKey: "updateEvery") == seconds ? .on : .off
            every.addItem(choice)
        }
        let auto = NSMenuItem(title: tr("auto"), action: nil, keyEquivalent: "")
        auto.submenu = every
        auto.image = NSImage(size: NSSize(width: 16, height: 16))  // lines the title up with the icon rows
        menu.addItem(auto)
        menu.addItem(.separator())
        menu.addItem(entry(tr("quit"), #selector(quit), "q", symbol: "xmark.square"))
    }

    // No knob values here: nothing calls this as they change, so they would be stale.
    func refresh() {
        let state = shared.snapshot()
        let setup = shared.config().setup
        item.isVisible = !setup.hideIcon
        item.button?.image = menuBarIcon(setup.icon, parked: !state.connected)
        // In labelColor, not a plain title's controlTextColor, which is dimmed like a template on the menu bars
        // of the displays not in use: see menuBarIcon.
        item.button?.attributedTitle = NSAttributedString(string: setup.showName ? clipped(setup.profile.name, to: 20) : "",
                                                          attributes: [.foregroundColor: NSColor.labelColor])
        item.button?.toolTip = "\(appName): \(state.connected ? state.port ?? "?" : tr("not_connected"))"
    }

    func makeWindow(_ title: String, _ content: NSView) -> NSWindow {
        let window = EditingWindow(contentRect: .zero, styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = title
        window.contentView = content
        window.isReleasedWhenClosed = false
        fit(window)
        window.center()
        return window
    }

    // Keeps the top edge where it is: setContentSize keeps the bottom one, so the title bar would move.
    func fit(_ window: NSWindow, animate: Bool = false) {
        guard let size = window.contentView?.fittingSize else { return }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true, animate: animate)
    }

    // A menu bar app is never frontmost on its own, and activation can be refused once the user has
    // moved to another app (as by the end of a calibration), hence ordering front regardless.
    func present(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    @objc func about() {
        openSettings()
        showTab(.about)
    }

    // Only the name is a link. The tooltip holds the URL, so hovering also shows where it goes.
    func link(_ name: String, _ url: String) -> NSButton {
        let link = NSButton(title: name, target: self, action: #selector(openLink))
        link.isBordered = false
        link.contentTintColor = .linkColor
        link.toolTip = url
        return link
    }

    func credit(_ prefix: String, _ name: String, _ url: String) -> NSStackView {
        let line = NSStackView(views: [NSTextField(labelWithString: prefix), link(name, url)])
        line.spacing = 3
        line.alignment = .firstBaseline
        return line
    }

    @objc func openLink(_ sender: NSButton) {
        if let url = sender.toolTip.flatMap(URL.init(string:)) { NSWorkspace.shared.open(url) }
    }


    @objc func pickProfile(_ sender: NSMenuItem) {
        switchProfile(sender.tag)
    }

    func stepProfile(_ by: Int) {
        switchProfile(shared.config().setup.stepped(by))
    }

    func switchProfile(_ index: Int) {
        var setup = shared.config().setup
        guard setup.profiles.indices.contains(index) else { return }
        setup.active = index
        shared.setSetup(setup)
        refresh()
        // Save makes the profile Settings shows active, so it has to follow or Save would switch back.
        if settingsWindow?.isVisible == true, index < draft.profiles.count {
            draft.active = index
            reloadDraft()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    // Only TheeJ's own zoom, so quitting leaves one from Accessibility Zoom alone.
    func applicationWillTerminate(_ notification: Notification) {
        if zoomTracker != nil { setZoom(0) }
    }

    @objc func reconnect() {
        shared.requestReconnect()
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }

    @objc func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            print("launch at login: \(error.localizedDescription)")
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    // The restart blinks the screen and the menu bar, so it's asked first. Cancel changes nothing.
    @objc func toggleDock() {
        guard alert(tr("dock_restart_title"), tr("dock_restart_text"), tr("dock_restart"), tr("cancel")) else { return }
        toggleDockTile()
    }

    @objc func toggleData() {
        prefs.set(!prefs.bool(forKey: "showDataInMenu"), forKey: "showDataInMenu")
    }

    @objc func pickUpdateEvery(_ sender: NSMenuItem) {
        prefs.set(sender.tag, forKey: "updateEvery")
    }

    // From the menu, by tag, or from the popup in Settings, by index.
    @objc func pickLanguage(_ sender: Any) {
        let index = (sender as? NSPopUpButton)?.indexOfSelectedItem ?? (sender as? NSMenuItem)?.tag ?? 0
        // Once the click is over: Settings is built again, and the popup that sent this with it.
        DispatchQueue.main.async { [self] in setLanguage(Language.allCases[index]) }
    }

    // The menu is rebuilt as it opens and the calibration window at each step. Settings is built once,
    // so it is built again, on the same tab, in the same place and with its unsaved edits.
    func setLanguage(_ language: Language) {
        prefs.set(language.rawValue, forKey: "language")
        refresh()
        if calibrator != nil { showStep() }
        guard let old = settingsWindow else { return }
        let tab = old.toolbar?.selectedItemIdentifier ?? .general
        let corner = NSPoint(x: old.frame.minX, y: old.frame.maxY)
        let visible = old.isVisible
        stopRecording()
        settingsWindow = nil
        old.orderOut(nil)  // not close(), which would take the app out of the Dock and ⌘Tab for a moment
        guard visible else { return }
        showSettings()
        showTab(tab)
        settingsWindow?.setFrameTopLeftPoint(corner)
    }
}
#endif
