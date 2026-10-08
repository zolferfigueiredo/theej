#if canImport(AppKit)
import AppKit
import Carbon.HIToolbox
import UniformTypeIdentifiers

extension NSToolbarItem.Identifier {
    static let general = Self("general")
    static let boards = Self("boards")
    static let about = Self("about")
}

// Settings' tabs in toolbar order, with their labels' keys and SF Symbols.
let settingsTabs: [(id: NSToolbarItem.Identifier, label: String, symbol: String)] = [
    (.general, "tab.general", "gearshape"), (.boards, "tab.boards", "slider.vertical.3"), (.about, "tab.about", "info.circle"),
]

let formWidth: CGFloat = 420  // every group, heading and footnote on General and About
let boardsWidth: CGFloat = 640  // the Boards tab, wider for the drawing

// Flipped, so a page taller than the window starts at its top rather than its bottom.
final class TopClipView: NSClipView {
    override var isFlipped: Bool { true }
}

// Six dots, two by three, which no SF Symbol draws.
let grip: NSImage = {
    let image = NSImage(size: NSSize(width: 8, height: 14), flipped: false) { _ in
        for column in 0..<2 {
            for row in 0..<3 { NSBezierPath(ovalIn: NSRect(x: column * 5, y: 1 + row * 5, width: 3, height: 3)).fill() }
        }
        return true
    }
    image.isTemplate = true
    return image
}()

// A shortcut's button, which records it, and a ✕ that removes it. One that switches profiles has to take ⌘
// or ⌃, be free in this app and in others; the keys a button presses can be any.
final class ShortcutField: NSStackView {
    let button = NSButton(title: "", target: nil, action: nil)
    let remove = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: tr("remove_shortcut"))!,
                          target: nil, action: nil)
    let hotKey: Bool
    var value: Shortcut? {
        didSet { show() }
    }
    var clashes: (Shortcut) -> Bool = { _ in false }
    let changed: (Shortcut?) -> Void

    init(_ value: Shortcut?, hotKey: Bool = true, changed: @escaping (Shortcut?) -> Void) {
        (self.value, self.hotKey, self.changed) = (value, hotKey, changed)
        super.init(frame: .zero)
        button.toolTip = tr("shortcut_tip")
        // With the ✕ after it, as wide as the name field: 156 + 8 + 16 = 180.
        button.widthAnchor.constraint(equalToConstant: 156).isActive = true
        button.target = menuBar
        button.action = #selector(MenuBar.recordShortcut)
        remove.toolTip = tr("remove_shortcut")
        remove.isBordered = false
        remove.widthAnchor.constraint(equalToConstant: 16).isActive = true
        remove.target = menuBar
        remove.action = #selector(MenuBar.removeShortcut)
        // The ✕ keeps its place while hidden, so the field doesn't move when a shortcut comes or goes.
        detachesHiddenViews = false
        addView(button, in: .leading)
        addView(remove, in: .leading)
        show()
    }

    required init?(coder: NSCoder) { nil }

    func show(recording: Bool = false, refused: String? = nil) {
        button.title = refused ?? (recording ? tr("press_shortcut") : value?.label ?? tr("record_shortcut"))
        button.contentTintColor = refused == nil ? nil : .systemOrange
        remove.isHidden = value == nil
    }
}

// A control row's grip. Dragged onto another row of its kind, it moves this control's jobs there.
final class KnobHandle: NSImageView, NSDraggingSource {
    var control = 0

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        guard let row = superview else { return }
        let snapshot = NSImage(size: row.bounds.size)
        if let rep = row.bitmapImageRepForCachingDisplay(in: row.bounds) {
            row.cacheDisplay(in: row.bounds, to: rep)
            snapshot.addRepresentation(rep)
        }
        let item = NSDraggingItem(pasteboardWriter: String(control) as NSString)
        item.setDraggingFrame(convert(row.bounds, from: row), contents: snapshot)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
}

// A group's rows, where a grip of the same group lands: on the row nearest the pointer, which lights up
// meanwhile. controls holds each row's control.
final class KnobList: NSStackView {
    var controls: [Int] = []

    private var lit: NSView? {
        didSet {
            oldValue?.layer?.backgroundColor = nil
            lit?.wantsLayer = true
            lit?.layer?.cornerRadius = 10
            lit?.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
        }
    }

    private var rows: [NSView] { arrangedSubviews.filter { !($0 is NSBox) } }  // not the separators

    private func target(_ info: NSDraggingInfo) -> Int? {
        guard let handle = info.draggingSource as? KnobHandle, controls.contains(handle.control) else { return nil }
        let y = convert(info.draggingLocation, from: nil).y
        let rows = rows
        return rows.indices.min { abs(rows[$0].frame.midY - y) < abs(rows[$1].frame.midY - y) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        lit = target(sender).map { rows[$0] }
        return lit == nil ? [] : .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { lit = nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        lit = nil
        guard let from = (sender.draggingSource as? KnobHandle)?.control, let row = target(sender), row < controls.count else { return false }
        let (to, controls) = (self.controls[row], self.controls)
        // Once the drag is over: the rows are rebuilt, the grip it started from with them.
        DispatchQueue.main.async { menuBar?.moveJobs(from: from, to: to, among: controls) }
        return true
    }
}

extension MenuBar: NSToolbarDelegate {
    // A second click keeps unsaved edits in an open window.
    @objc func openSettings() {
        if settingsWindow?.isVisible != true {
            draft = shared.config().setup
            showTab(.general)  // not the tab it was closed on
        }
        showSettings()
        settingsWindow?.makeFirstResponder(nil)
    }

    // Three tabs of System Settings groups. Built once, and again in a new language; in between only the
    // rows and values change.
    func showSettings() {
        if settingsWindow != nil {
            showM1ddc()
            reloadDraft()
            fitSettings()
        } else {
            buildPages()
            // Each page scrolls when the screen is too short for it.
            let scroll = NSScrollView()
            scroll.contentView = TopClipView()
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.drawsBackground = false
            let window = makeWindow("", scroll)
            let toolbar = NSToolbar(identifier: "settings")
            toolbar.delegate = self
            window.toolbar = toolbar
            window.toolbarStyle = .preference
            // Else closing the window mid-recording would leave every shortcut off.
            NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window,
                                                   queue: .main) { [weak self] _ in
                if self?.sheet == nil { self?.stopRecording() }
            }
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                   queue: .main) { [weak self] _ in
                self?.stopRecording()
                shared.setWatching(nil)
                NSApp.setActivationPolicy(.accessory)
            }
            settingsWindow = window
            showTab(.general)
            window.center()  // again, now that the toolbar has made it taller
        }
        // A regular app while Settings is open, so Cmd+Tab can switch back to it.
        NSApp.setActivationPolicy(.regular)
        present(settingsWindow!)
    }

    // The three pages, built once and again in a new language.
    func buildPages() {
        applyButtons = []
        boardsFooter = nil
        for control: NSControl in [showName, hideIcon, iconPicker, showProfiles] {
            control.target = self
            control.action = #selector(toggleOption)
        }
        for toggle in [showName, hideIcon, showProfiles] { toggle.controlSize = .mini }
        iconPicker.isBordered = false
        iconPicker.removeAllItems()
        for style in IconStyle.allCases {
            iconPicker.addItem(withTitle: style.title)
            iconPicker.lastItem?.image = makeIcon(style, parked: false, side: 16)
        }
        // Each language is named in itself, so it can always be found.
        languagePicker.isBordered = false
        languagePicker.removeAllItems()
        for language in Language.allCases { languagePicker.addItem(withTitle: "\(language.flag) \(language.name)") }
        languagePicker.selectItem(at: Language.allCases.firstIndex(of: .current) ?? 0)
        languagePicker.target = self
        languagePicker.action = #selector(pickLanguage)
        showNameLabel.stringValue = tr("show_name")
        iconLabel.stringValue = tr("icon")
        profileListLabel.stringValue = tr("profile_list")
        let appRows = NSStackView()
        let appGroup = group(appRows)
        setRows(appRows, [row([label(tr("language"))], languagePicker),
                          row([label(tr("hide_icon"), note: tr("hide_icon_note"))], hideIcon),
                          row([showNameLabel], showName),
                          row([iconLabel], iconPicker),
                          row([profileListLabel], showProfiles)])
        let boardsGroup = group(boardRows)
        let add = NSButton(title: tr("boards.add"), target: self, action: #selector(addBoard))
        let m1ddc = isAppleSilicon ? [m1ddcGroup()] : []  // m1ddc runs on Apple Silicon only
        let general = page(m1ddc + [header(tr("boards.title"), trailing: [add]), boardsGroup, header(tr("general.app")),
                                    appGroup, saveFooter()])
        for view in m1ddc + [boardsGroup, appGroup] { general.setCustomSpacing(24, after: view) }
        boardsPage.orientation = .vertical
        boardsPage.alignment = .leading
        boardsPage.spacing = 8
        boardsPage.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        boardsPage.setHuggingPriority(.defaultHigh, for: .horizontal)
        tabs = [.general: general, .boards: boardsPage, .about: aboutPage()]
        reloadDraft()
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { settingsTabs.map(\.id) }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { settingsTabs.map(\.id) }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { settingsTabs.map(\.id) }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let tab = settingsTabs.first(where: { $0.id == id }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = tr(tab.label)
        item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: item.label)
        item.target = self
        item.action = #selector(pickTab)
        return item
    }

    @objc func pickTab(_ sender: NSToolbarItem) { showTab(sender.itemIdentifier) }

    func showTab(_ id: NSToolbarItem.Identifier) {
        guard let window = settingsWindow, let page = tabs[id] else { return }
        window.toolbar?.selectedItemIdentifier = id
        window.title = settingsTabs.first { $0.id == id }.map { tr($0.label) } ?? ""
        reloadDraft()
        (window.contentView as? NSScrollView)?.documentView = page
        fitSettings(animate: window.isVisible)
    }

    var selectedTab: NSToolbarItem.Identifier? { settingsWindow?.toolbar?.selectedItemIdentifier }

    // The window takes the page's own size, or the screen's height where that is less and the page scrolls.
    // It grows and shrinks from its top edge, which it moves down only as far as needed to stay on screen.
    func fitSettings(animate: Bool = false) {
        guard let window = settingsWindow, let page = (window.contentView as? NSScrollView)?.documentView,
              let screen = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        page.setFrameSize(page.fittingSize)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: page.frame.size))
        frame.size.height = min(frame.height, screen.height)
        frame.origin.x = window.frame.minX
        frame.origin.y = max(min(window.frame.maxY, screen.maxY) - frame.height, screen.minY)
        window.setFrame(frame, display: true, animate: animate)
    }

    // Headings sit 8 above their group. Groups sit further apart, as the caller sets.
    func page(_ views: [NSView], width: CGFloat = formWidth) -> NSStackView {
        let page = NSStackView(views: views)
        page.orientation = .vertical
        page.alignment = .leading
        page.spacing = 8
        page.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        page.setHuggingPriority(.defaultHigh, for: .horizontal)  // else fittingSize drops the right inset
        for view in views where !(view is NSBox) { view.widthAnchor.constraint(equalToConstant: width).isActive = true }
        return page
    }

    func saveFooter() -> NSStackView {
        let close = NSButton(title: tr("close"), target: nil, action: #selector(NSWindow.performClose(_:)))
        let apply = NSButton(title: tr("apply"), target: self, action: #selector(saveSettings))
        apply.keyEquivalent = "\r"
        applyButtons.append(apply)
        let footer = NSStackView()
        footer.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        footer.addView(close, in: .leading)
        footer.addView(apply, in: .trailing)
        return footer
    }

    func aboutPage() -> NSStackView {
        let icon = NSImageView(image: makeAppIcon(side: 96, scale: 2))
        icon.widthAnchor.constraint(equalToConstant: 96).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 96).isActive = true
        let name = NSTextField(labelWithString: appName)
        name.font = .boldSystemFont(ofSize: 16)
        let version = NSTextField(labelWithString: tr("version", ["version": appVersion]))
        version.textColor = .secondaryLabelColor
        let check = NSButton(title: tr("check"), target: self, action: #selector(checkNow))
        check.isEnabled = !checking && UpdateProgress.underway == nil
        checkButton = check
        let website = link(tr("website"), "https://theej.zolfer.com/")
        let madeBy = credit(tr("made_by"), "zolfer.com", "https://zolfer.com/")
        let windows = credit(tr("on_windows"), "WeeJ", "https://weej.zolfer.com/")
        let inspired = credit(tr("inspired_by"), "deej", "https://github.com/omriharel/deej")
        let footer = saveFooter()
        footer.widthAnchor.constraint(equalToConstant: formWidth).isActive = true
        let page = NSStackView(views: [icon, name, version, check, website, madeBy, windows, inspired, footer])
        page.orientation = .vertical
        page.alignment = .centerX
        page.spacing = 4
        page.setCustomSpacing(12, after: icon)
        page.setCustomSpacing(16, after: version)
        page.setCustomSpacing(16, after: check)
        for line in [website, madeBy, windows] { page.setCustomSpacing(10, after: line) }
        page.setCustomSpacing(24, after: inspired)
        page.edgeInsets = NSEdgeInsets(top: 24, left: 20, bottom: 20, right: 20)
        page.widthAnchor.constraint(equalToConstant: formWidth + 40).isActive = true  // as wide as General
        return page
    }

    // Whether m1ddc, which external screens need, is installed, with a button that installs it.
    func m1ddcGroup() -> NSBox {
        let site = link("github.com/waydabber/m1ddc", "https://github.com/waydabber/m1ddc")
        site.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        m1ddcSupport = NSStackView(views: [small(tr("m1ddc.support")), site])
        m1ddcSupport.spacing = 3
        m1ddcSupport.alignment = .firstBaseline
        let text = NSStackView(views: [NSTextField(labelWithString: "m1ddc"), small(tr("m1ddc.note")), m1ddcSupport])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        m1ddcStatus.textColor = .secondaryLabelColor
        m1ddcButton.target = self
        m1ddcButton.action = #selector(installM1ddc)
        let row = row([text], m1ddcStatus, m1ddcButton)
        // As with a control's list, the row centres its text without keeping its padding round it.
        text.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 8).isActive = true
        text.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -8).isActive = true
        let rows = NSStackView()
        let box = group(rows)
        setRows(rows, [row])
        showM1ddc()
        return box
    }

    // Checked whenever Settings opens or is rebuilt, and by Refresh. A path found here also reaches
    // writeDDC, so screens work without restarting TheeJ.
    func showM1ddc() {
        guard isAppleSilicon else { return }
        let path = findM1ddc()
        ddcQueue.async { m1ddcPath = path }
        m1ddcStatus.stringValue = path == nil ? "⚠️ " + tr("m1ddc.missing") : "✅ " + tr("m1ddc.installed")
        m1ddcButton.title = tr(m1ddcInstallStarted ? "m1ddc.refresh" : "m1ddc.install")
        m1ddcButton.isHidden = path != nil
        m1ddcSupport.isHidden = path != nil
    }

    // A .command file opens in Terminal and runs there, with no Automation permission to ask for. Its
    // last line opens TheeJ again, which brings Settings back to check once brew is done.
    @objc func installM1ddc() {
        if !m1ddcInstallStarted {
            let script = FileManager.default.temporaryDirectory.appendingPathComponent("install-m1ddc.command")
            let text = """
            #!/bin/zsh
            export PATH="/opt/homebrew/bin:$PATH"
            echo '$ brew install m1ddc'
            command -v brew >/dev/null || { echo 'Homebrew is needed first: https://brew.sh'; exit 1; }
            brew install m1ddc && open -b \(Bundle.main.bundleIdentifier ?? "com.zolfer.theej")

            """
            guard (try? text.write(to: script, atomically: true, encoding: .utf8)) != nil,
                  (try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)) != nil,
                  NSWorkspace.shared.open(script) else { return NSSound.beep() }
            m1ddcInstallStarted = true
        }
        showM1ddc()
        fitSettings()
    }

    // Headings, footnotes and the footer sit on the same text edge as the rows' labels.
    func header(_ title: String, leading: [NSView] = [], trailing: [NSView] = []) -> NSStackView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let header = NSStackView()
        header.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        for view in [heading] + leading { header.addView(view, in: .leading) }
        for view in trailing { header.addView(view, in: .trailing) }
        return header
    }

    func small(_ text: String, _ color: NSColor = .secondaryLabelColor) -> NSTextField {
        let small = NSTextField(labelWithString: text)
        small.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        small.textColor = color
        return small
    }

    func footnote(_ text: String, width: CGFloat = formWidth) -> NSStackView {
        let note = NSTextField(wrappingLabelWithString: text)
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = width - 24
        let stack = NSStackView(views: [note])
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        return stack
    }

    // A row's title, with an optional line of small type under it, as System Settings does.
    func label(_ title: String, note: String? = nil, noteColor: NSColor = .secondaryLabelColor) -> NSView {
        let label = NSTextField(labelWithString: title)
        guard let note else { return label }
        let stack = NSStackView(views: [label, small(note, noteColor)])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        return stack
    }

    func group(_ rows: NSStackView, width: CGFloat = formWidth) -> NSBox {
        rows.orientation = .vertical
        rows.spacing = 0
        rows.alignment = .trailing  // separators are narrower than the rows, which insets them on the left
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 10
        box.borderColor = .separatorColor
        box.fillColor = .quaternarySystemFill
        box.addSubview(rows)
        rows.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: box.topAnchor),
            rows.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            rows.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            box.widthAnchor.constraint(equalToConstant: width),
        ])
        return box
    }

    func row(_ leading: [NSView], _ trailing: NSView...) -> NSStackView {
        let row = NSStackView()
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 38).isActive = true  // one height whatever the control
        for view in leading { row.addView(view, in: .leading) }
        for view in trailing { row.addView(view, in: .trailing) }
        return row
    }

    // A row of grey text in a group that has nothing else to show.
    func emptyRow(_ text: String) -> NSStackView {
        let empty = NSTextField(wrappingLabelWithString: text)
        empty.textColor = .secondaryLabelColor
        let row = NSStackView()
        row.edgeInsets = NSEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
        row.addView(empty, in: .center)
        return row
    }

    func setRows(_ stack: NSStackView, _ rows: [NSStackView]) {
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let line = NSBox()
                line.boxType = .separator
                stack.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -12).isActive = true
            }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    // Rebuilt on every change: General's boards and options, and the Boards tab.
    func reloadDraft() {
        stopRecording()
        setRows(boardRows, draft.boards.isEmpty ? [emptyRow(tr("boards.none"))] : draft.boards.map(boardRow))
        showName.state = draft.showName ? .on : .off
        showProfiles.state = draft.showProfiles ? .on : .off
        hideIcon.state = draft.hideIcon ? .on : .off
        iconPicker.selectItem(at: IconStyle.allCases.firstIndex(of: draft.icon) ?? 0)
        dimMenuBarOptions()
        reloadBoards()
        dimApply()
    }

    // A board on General: switched on or off at once, its name opening it on the Boards tab, its status
    // and its own settings.
    func boardRow(_ board: Board) -> NSStackView {
        let toggle = NSSwitch()
        toggle.controlSize = .mini
        toggle.state = board.enabled ? .on : .off
        toggle.identifier = NSUserInterfaceItemIdentifier(board.id)
        toggle.target = self
        toggle.action = #selector(toggleBoard)
        toggle.setAccessibilityLabel(tr("boards.on", ["name": board.name]))
        let name = NSButton(title: clipped(board.name, to: 30), target: self, action: #selector(openBoard))
        name.isBordered = false
        name.contentTintColor = .linkColor
        name.identifier = toggle.identifier
        let text = NSStackView(views: [name, small(tr("device.type.\(board.type.rawValue)"))])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 0
        let (line, color) = statusLine(board)
        let status = small(line, color)
        let gear = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: tr("boards.settings"))!,
                            target: self, action: #selector(openBoardSettings))
        gear.isBordered = false
        gear.toolTip = tr("boards.settings")
        gear.identifier = toggle.identifier
        return row([toggle, text], status, gear)
    }

    func statusLine(_ board: Board) -> (String, NSColor) {
        guard board.enabled else { return (tr("status.off"), .secondaryLabelColor) }
        let status = shared.status(board.id)
        if status.connected { return (tr("status.connected"), .systemGreen) }
        if status.busy { return (tr("port_busy", ["port": status.port ?? "?"]), .systemOrange) }
        return (tr("status.disconnected"), .secondaryLabelColor)
    }

    @objc func toggleBoard(_ sender: NSSwitch) {
        guard let id = sender.identifier?.rawValue else { return }
        let on = sender.state == .on
        changeAtOnce(id) { $0.enabled = on }
    }

    @objc func openBoard(_ sender: NSButton) {
        shownBoard = sender.identifier?.rawValue
        showTab(.boards)
    }

    // A change that lands at once, as the switch, Draw or List and a board's own settings do: in what is
    // saved, and in the draft, so Apply has nothing to undo.
    func changeAtOnce(_ id: String, _ change: (inout Board) -> Void) {
        var setup = shared.config().setup
        if let index = setup.index(of: id) { change(&setup.boards[index]) }
        if let index = draft.index(of: id) { change(&draft.boards[index]) }
        shared.setSetup(setup)
        startBoards()
        refresh()
        reloadDraft()
        fitSettings()
    }

    // Apply is on only while it would change something.
    func dimApply() {
        let saved = shared.config().setup
        for button in applyButtons { button.isEnabled = draft != saved }
    }

    @objc func toggleOption() {
        draft.showName = showName.state == .on
        draft.showProfiles = showProfiles.state == .on
        draft.hideIcon = hideIcon.state == .on
        draft.icon = IconStyle.allCases[iconPicker.indexOfSelectedItem]
        dimMenuBarOptions()
    }

    // With the icon hidden there is nothing in the menu bar to name, draw or open.
    func dimMenuBarOptions() {
        for control: NSControl in [showName, iconPicker, showProfiles] { control.isEnabled = !draft.hideIcon }
        for label in [showNameLabel, iconLabel, profileListLabel] {
            label.textColor = draft.hideIcon ? .disabledControlTextColor : .labelColor
        }
    }

    func confirm(_ message: String, _ info: String, in window: NSWindow? = nil, then action: @escaping () -> Void) {
        guard let window = window ?? settingsWindow else { return }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.addButton(withTitle: tr("remove")).hasDestructiveAction = true
        alert.addButton(withTitle: tr("cancel"))
        alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { action() } }
    }

    // The shortcuts are off while recording, so pressing one records it instead of switching. A click on
    // the field being recorded stops, and on another field records that one instead.
    @objc func recordShortcut(_ sender: NSButton) {
        guard let field = sender.superview as? ShortcutField else { return }
        let again = recordingField === field
        stopRecording()
        guard !again else { return }
        registerHotKeys(nil)
        recordingField = field
        field.show(recording: true)
        recorder = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.record(event)
            return nil
        }
    }

    // Needing ⌘ or ⌃ keeps a profile's shortcut from swallowing typing in every app. One that is refused
    // says why, and recording goes on for another try.
    func record(_ event: NSEvent) {
        guard let field = recordingField else { return }
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        let shortcut = Shortcut(keyCode: event.keyCode, modifiers: flags.rawValue,
                                key: event.characters(byApplyingModifiers: []) ?? "")
        if Int(event.keyCode) == kVK_Delete && flags.isEmpty {
            field.value = nil
            field.changed(nil)
        } else if Int(event.keyCode) != kVK_Escape {
            if field.hotKey {
                var refused: String?
                if shortcut.key.isEmpty || flags.isDisjoint(with: [.command, .control]) {
                    refused = tr("shortcut_tip")
                } else if field.clashes(shortcut) {
                    refused = tr("shortcut.clash")
                } else if let probe = registerHotKey(shortcut, id: probeHotKey) {
                    UnregisterEventHotKey(probe)
                } else {
                    refused = tr("shortcut.taken")
                }
                if let refused {
                    NSSound.beep()
                    field.show(refused: refused)
                    return
                }
            }
            field.value = shortcut
            field.changed(shortcut)
        }
        stopRecording()
    }

    func stopRecording() {
        if let recorder {
            NSEvent.removeMonitor(recorder)
            registerHotKeys(shared.config().setup)
        }
        recorder = nil
        recordingField?.show()
        recordingField = nil
    }

    @objc func removeShortcut(_ sender: NSButton) {
        guard let field = sender.superview as? ShortcutField else { return }
        stopRecording()
        field.value = nil
        field.changed(nil)
    }

    // An app's volume is set by capturing its audio, which macOS has to allow. It asks the first time,
    // and the answer only reaches a TheeJ started after it.
    func askForAudioCapture() {
        guard !audioCaptureAllowed() else { return }
        requestAudioCapture { [self] granted in
            guard !granted, alert(tr("audio_title"), tr("audio_text"), tr("open_settings"), tr("later")) else { return }
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
        }
    }

    // A button that presses keys or media keys needs macOS to allow it, which it asks for in its own words.
    func askForKeyAccess() {
        let pressesKeys = draft.boards.contains { board in
            board.enabled && board.profiles.contains { $0.buttons.values.joined().contains(where: postsKeys) }
        }
        if pressesKeys, !CGPreflightPostEventAccess() { CGRequestPostEventAccess() }
    }

    @objc func saveSettings() {
        let saved = shared.config().setup
        for b in draft.boards.indices {
            if draft.boards[b].name.trimmingCharacters(in: .whitespaces).isEmpty {
                draft.boards[b].name = tr("device.type.\(draft.boards[b].type.rawValue)")
            }
            for p in draft.boards[b].profiles.indices {
                if draft.boards[b].profiles[p].name.trimmingCharacters(in: .whitespaces).isEmpty {
                    draft.boards[b].profiles[p].name = tr("profile_n", ["n": p + 1])
                }
                // An action whose setting was never filled in, as a website with no address, does nothing.
                draft.boards[b].profiles[p].buttons = draft.boards[b].profiles[p].buttons.mapValues { $0.filter(validAction) }
                    .filter { !$0.value.isEmpty }
            }
            // A board whose profile changes gets its mutes back first, and its knobs start from their new jobs.
            if let before = saved.board(draft.boards[b].id), before.active != draft.boards[b].active {
                engineQueue.async {
                    unmuteAll(before)
                    boardStates[before.id]?.mixer.forgetKnobs()
                }
            }
        }
        shared.setSetup(draft)
        startBoards()
        refresh()
        reloadDraft()
        keepAppVolumes(for: draft.apps)
        if !draft.apps.isEmpty { askForAudioCapture() }
        askForKeyAccess()
    }
}
#endif
