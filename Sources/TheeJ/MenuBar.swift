import AppKit
import ServiceManagement

final class MenuBar: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate, NSTextFieldDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var aboutWindow: NSWindow?
    var checking = false  // an update check or install is running
    var settingsWindow: NSWindow?
    var draft = Setup()
    let profilePicker = NSPopUpButton()
    let profileEdit = NSSegmentedControl()
    let profileName = NSTextField(string: "")
    let shortcutButton = NSButton(title: "", target: nil, action: nil)
    let removeShortcutButton = NSButton(
        image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remove shortcut")!,
        target: nil, action: nil)
    var recorder: Any?  // the key monitor while a shortcut is being recorded
    let profileRows = NSStackView()
    let knobRows = NSStackView()
    let knobEdit = NSSegmentedControl()
    let invertKnobs = NSSwitch()
    let showName = NSSwitch()
    let hideIcon = NSSwitch()
    let showNameLabel = NSTextField(labelWithString: "Show profile name")
    let iconPicker = NSPopUpButton()
    let iconLabel = NSTextField(labelWithString: "Icon")
    var calibrationWindow: NSWindow?
    var calibrator: Calibrator?
    var calibrationOffered = false
    let stepTitle = NSTextField(labelWithString: "")
    let stepBody = NSTextField(wrappingLabelWithString: "")
    let stepProgress = NSTextField(labelWithString: "")
    let skipButton = NSButton(title: "", target: nil, action: nil)

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
        let data = entry("Show data below", #selector(toggleData), "")
        data.state = showData ? .on : .off
        menu.addItem(data)
        if showData, state.connected {
            state.lines.forEach { menu.addItem(label($0)) }
        }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Profiles"))
        for (index, profile) in setup.profiles.enumerated() {
            let mi = entry(profile.name, #selector(pickProfile), profile.shortcut?.key ?? "")
            mi.keyEquivalentModifierMask = profile.shortcut?.flags ?? []
            mi.tag = index
            mi.state = index == setup.active ? .on : .off
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        menu.addItem(entry("Settings", #selector(openSettings), ","))
        let calibrateItem = entry("Calibrate", #selector(calibrate), "")
        calibrateItem.isEnabled = state.connected
        menu.addItem(calibrateItem)
        menu.addItem(.separator())
        menu.addItem(label(state.connected ? "Connected: \(state.port ?? "?")" : "Not connected"))
        menu.addItem(entry("Reconnect", #selector(reconnect), ""))
        menu.addItem(.separator())
        // Registering from anywhere else (a build folder) would point the login item at a bundle that disappears.
        let login = entry("Launch at login", #selector(toggleLogin), "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.isEnabled = Bundle.main.bundlePath.hasPrefix("/Applications/")
        menu.addItem(login)
        let dock = entry("Keep in Dock", #selector(toggleDock), "")
        dock.state = inDock() ? .on : .off
        menu.addItem(dock)
        menu.addItem(.separator())
        menu.addItem(entry("About \(appName)", #selector(about), "", symbol: "info.circle"))
        menu.addItem(.separator())
        let check = entry("Check for updates…", #selector(checkNow), "", symbol: "arrow.down.circle")
        check.isEnabled = !checking
        if let version = availableUpdate() {
            check.attributedTitle = updateAvailableTitle(version)
            check.image = updateAvailableIcon()
        }
        menu.addItem(check)
        let every = NSMenu()
        for (seconds, title) in [(86400, "Daily"), (604800, "Weekly"), (0, "Never")] {
            let choice = entry(title, #selector(pickUpdateEvery), "")
            choice.tag = seconds
            choice.state = prefs.integer(forKey: "updateEvery") == seconds ? .on : .off
            every.addItem(choice)
        }
        let auto = NSMenuItem(title: "Check automatically", action: nil, keyEquivalent: "")
        auto.submenu = every
        auto.image = NSImage(size: NSSize(width: 16, height: 16))  // lines the title up with the icon rows
        menu.addItem(auto)
        menu.addItem(.separator())
        menu.addItem(entry("Quit \(appName)", #selector(quit), "q", symbol: "xmark.square"))
    }

    // No knob values here: nothing calls this as they change, so they would be stale.
    func refresh() {
        let state = shared.snapshot()
        let setup = shared.config().setup
        item.isVisible = !setup.hideIcon
        item.button?.image = makeIcon(setup.icon, parked: !state.connected)
        item.button?.title = setup.showName ? setup.profile.name : ""
        item.button?.toolTip = "\(appName): \(state.connected ? state.port ?? "connected" : "not connected")"
    }

    func makeWindow(_ title: String, _ content: NSView) -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = title
        window.contentView = content
        window.isReleasedWhenClosed = false
        fit(window)
        window.center()
        return window
    }

    // Keeps the top edge where it is: setContentSize keeps the bottom one, so the title bar would move.
    func fit(_ window: NSWindow) {
        guard let size = window.contentView?.fittingSize else { return }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true)
    }

    // A menu bar app is never frontmost on its own, and activation can be refused once the user has
    // moved to another app (as by the end of a calibration), hence ordering front regardless.
    func present(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    // Same layout as BiHan Brightness's About window.
    @objc func about() {
        if aboutWindow == nil {
            let name = NSTextField(labelWithString: appName)
            name.font = .boldSystemFont(ofSize: 16)
            let text = NSStackView(views: [name,
                                           credit("By", "Zolfer Figueiredo", "http://zolfer.com/"),
                                           credit("Inspired by", "deej", "https://github.com/omriharel/deej"),
                                           NSTextField(labelWithString: "Version \(appVersion)"),
                                           link("Website", "https://theej.zolfer.com/")])
            text.orientation = .vertical
            text.setCustomSpacing(12, after: name)
            let logo = NSImageView(image: makeAppIcon(side: 96, scale: 2))
            logo.widthAnchor.constraint(equalToConstant: 96).isActive = true
            logo.heightAnchor.constraint(equalToConstant: 96).isActive = true
            let row = NSStackView(views: [logo, text])
            row.spacing = 24
            row.edgeInsets = NSEdgeInsets(top: 16, left: 24, bottom: 24, right: 40)
            aboutWindow = makeWindow("", row)
        }
        present(aboutWindow!)
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

    @objc func toggleDock() {
        toggleDockTile()
    }

    @objc func toggleData() {
        prefs.set(!prefs.bool(forKey: "showDataInMenu"), forKey: "showDataInMenu")
    }

    @objc func pickUpdateEvery(_ sender: NSMenuItem) {
        prefs.set(sender.tag, forKey: "updateEvery")
    }
}
