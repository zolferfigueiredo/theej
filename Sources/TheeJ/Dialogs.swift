#if canImport(AppKit)
import AppKit

private let dialogWidth: CGFloat = 460

// A sheet on Settings, as WeeJ's dialogs: a title, a group of rows and its buttons. It keeps itself alive
// through MenuBar.dialog until it closes.
class Dialog: NSObject, NSTextFieldDelegate {
    unowned let owner: MenuBar
    let window = EditingWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    let rows = NSStackView()
    let heading = NSTextField(labelWithString: "")
    let buttons = NSStackView()

    init(owner: MenuBar) {
        self.owner = owner
        super.init()
        heading.font = .boldSystemFont(ofSize: 13)
        let box = owner.group(rows, width: dialogWidth)
        let content = NSStackView(views: [heading, box, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        buttons.widthAnchor.constraint(equalToConstant: dialogWidth).isActive = true
        window.contentView = content
    }

    func button(_ title: String, _ action: Selector, key: String = "") -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.keyEquivalent = key
        return button
    }

    func show(_ rows: [NSStackView], leading: [NSButton] = [], trailing: [NSButton]) {
        owner.setRows(self.rows, rows)
        for view in buttons.views { buttons.removeView(view) }
        for button in leading { buttons.addView(button, in: .leading) }
        for button in trailing { buttons.addView(button, in: .trailing) }
        owner.fit(window)
        guard owner.dialog !== self else { return }
        owner.closeSheet()
        owner.dialog = self
        owner.sheet = window
        owner.settingsWindow?.beginSheet(window)
    }

    @objc func close() {
        owner.stopRecording()
        owner.settingsWindow?.endSheet(window)
        window.orderOut(nil)
        if owner.dialog === self {
            owner.dialog = nil
            owner.sheet = nil
        }
    }

    // A row whose note goes under it, the whole width, so a long one wraps instead of widening the sheet.
    func formRow(_ title: String, note: String? = nil, _ controls: NSView...) -> NSStackView {
        let line = NSStackView()
        line.addView(NSTextField(labelWithString: title), in: .leading)
        for control in controls { line.addView(control, in: .trailing) }
        let row = NSStackView(views: [line])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 4
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 38).isActive = true
        line.widthAnchor.constraint(equalToConstant: dialogWidth - 24).isActive = true
        if let note {
            let text = NSTextField(wrappingLabelWithString: note)
            text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            text.textColor = .secondaryLabelColor
            text.preferredMaxLayoutWidth = dialogWidth - 24
            row.addArrangedSubview(text)
        }
        return row
    }

    func field(_ value: String, placeholder: String = "") -> NSTextField {
        let field = NSTextField(string: value)
        field.placeholderString = placeholder
        field.bezelStyle = .roundedBezel
        field.widthAnchor.constraint(equalToConstant: 180).isActive = true
        field.delegate = self
        return field
    }

    func popup(_ titles: [String], selected: Int) -> NSPopUpButton {
        let popup = NSPopUpButton()
        for title in titles { popup.menu?.addItem(withTitle: title, action: nil, keyEquivalent: "") }
        popup.selectItem(at: selected)
        popup.target = self
        return popup
    }

    // Where a board is: Automatic or a serial port for a DIY board, a MIDI input for any other, Automatic
    // finding the SMC-Mixer. A port another board is set to says so.
    func devicePopup(_ type: BoardType, _ value: String, besides id: String?) -> NSPopUpButton {
        let popup = NSPopUpButton()
        let others = owner.draft.boards.filter { $0.id != id && $0.type.isMIDI == type.isMIDI }
        func add(_ title: String, _ port: String) {
            let item = popup.menu?.addItem(withTitle: title, action: nil, keyEquivalent: "")
            item?.representedObject = port
        }
        add(tr(type == .midi ? "device.pick_input" : "port_auto"), "")
        let ports = type == .diy ? serialPorts() : MIDI.sources().map(\.name)
        for port in ports + (value.isEmpty || ports.contains(value) ? [] : [value]) {
            add(others.first { $0.port == port }.map { tr("device.used_by", ["port": port, "board": $0.name]) } ?? port, port)
        }
        popup.selectItem(at: popup.itemArray.firstIndex { $0.representedObject as? String == value } ?? 0)
        popup.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true
        return popup
    }

    func refreshButton(_ action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: tr("refresh"))!,
                              target: self, action: action)
        button.isBordered = false
        button.toolTip = tr("refresh")
        return button
    }

    func portNote(_ type: BoardType) -> String { tr(type == .midi ? "mixer_port_note" : "port_note") }
}

// Name, type, where it is and, for a DIY board or another MIDI controller, how many knobs, faders and
// buttons it has. Next goes on to calibrate it; an SMC-Mixer's controls are known, so it is just added.
final class AddBoardDialog: Dialog {
    private var type = BoardType.diy
    private lazy var name = field("", placeholder: tr("add.name_hint"))
    private let types = NSSegmentedControl()
    private var device = NSPopUpButton()
    private var baud = NSPopUpButton()
    private let counts = (0..<3).map { _ in NSTextField(string: "0") }
    private lazy var confirm = button("", #selector(add), key: "\r")

    override init(owner: MenuBar) {
        super.init(owner: owner)
        heading.stringValue = owner.boardSetup.map { tr("setup.board", ["n": $0.done + 1, "of": $0.total]) } ?? tr("add.title")
        types.segmentCount = 3
        for (index, kind) in BoardType.allCases.enumerated() {
            types.setLabel(tr("device.type.\(kind.rawValue)"), forSegment: index)
        }
        types.selectedSegment = 0
        types.target = self
        types.action = #selector(pickType)
        counts[0].stringValue = "4"
        let formatter = NumberFormatter()
        formatter.allowsFloats = false
        formatter.minimum = 0
        formatter.maximum = 64
        for count in counts {
            count.formatter = formatter
            count.bezelStyle = .roundedBezel
            count.alignment = .right
            count.widthAnchor.constraint(equalToConstant: 60).isActive = true
            count.delegate = self
        }
        build()
    }

    private func build() {
        device = devicePopup(type, type == .smc ? smcSource() : "", besides: nil)
        device.target = self
        device.action = #selector(check)
        baud = popup(baudRates.map(String.init), selected: 0)
        var list = [formRow(tr("name"), name),
                    formRow(tr("device.type"), note: tr("add.type_note.\(type.rawValue)"), types),
                    formRow(tr("port"), note: portNote(type), refreshButton(#selector(refresh)), device)]
        if type == .diy { list.append(formRow(tr("baud_rate"), note: tr("baud_note"), baud)) }
        if type != .smc {
            for (title, count) in zip([tr("knobs"), tr("list.faders"), tr("list.buttons")], counts) {
                list.append(formRow(title, count))
            }
        }
        confirm.title = tr(type == .smc ? "add.add" : "add.next")
        show(list, trailing: [button(tr("cancel"), #selector(cancel), key: "\u{1b}"), confirm])
        check()
    }

    @objc private func cancel() {
        owner.boardSetup = nil
        close()
    }

    // The SMC-Mixer plugged in, Master before Private, if there is one.
    private func smcSource() -> String {
        let names = MIDI.sources().map(\.name).filter(isSMCName)
        return names.first { $0.lowercased().hasSuffix("master") } ?? names.first ?? ""
    }

    @objc private func pickType() {
        type = BoardType.allCases[types.selectedSegment]
        build()
    }

    @objc private func refresh() { build() }

    private var port: String { device.selectedItem?.representedObject as? String ?? "" }

    private func count(_ index: Int) -> Int { min(max(Int(counts[index].stringValue) ?? 0, 0), 64) }

    @objc private func check() {
        let named = !name.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
        let found = type != .midi || !port.isEmpty
        let controls = type == .smc || (0..<3).map(count).reduce(0, +) > 0
        confirm.isEnabled = named && found && controls
    }

    func controlTextDidChange(_ obj: Notification) { check() }

    @objc private func add() {
        var setup = shared.config().setup
        let id = nextBoardID(setup.added)
        var board = Board.make(id: id, name: name.stringValue.trimmingCharacters(in: .whitespaces), type: type,
                               knobs: count(0), faders: count(1), buttons: count(2), profileName: tr("default_profile"))
        board.port = port
        board.baud = baudRates[baud.indexOfSelectedItem]
        setup.boards.append(board)
        setup.added += 1
        owner.draft.boards.append(board)
        owner.draft.added = setup.added
        shared.setSetup(setup)
        close()
        startBoards()
        owner.shownBoard = id
        owner.reloadDraft()
        owner.fitSettings()
        owner.boardSetup?.done += 1
        if type == .smc { owner.nextInSetup() } else { owner.startWizard(id) }
    }
}

// A board's own settings, saved at once by Save, as WeeJ's gear.
final class BoardSettingsDialog: Dialog {
    private var board: Board
    private lazy var name = field(board.name)
    private var device = NSPopUpButton()
    private var baud = NSPopUpButton()
    private var speed = NSPopUpButton()
    private var lights = NSPopUpButton()

    init(owner: MenuBar, board: Board) {
        self.board = board
        super.init(owner: owner)
        build()
    }

    // The first DIY board's port, when one was given as TheeJ started.
    private var forced: String? {
        guard board.type == .diy, owner.draft.boards.first(where: { $0.type == .diy })?.id == board.id else { return nil }
        return portOverride
    }

    private func build() {
        heading.stringValue = tr("boards.settings_of", ["name": board.name])
        let (line, color) = owner.statusLine(board)
        let status = shared.status(board.id)
        let statusText = owner.small(status.connected ? tr("connected", ["port": status.port ?? "?"]) : line, color)
        var list = [formRow(tr("name"), name),
                    formRow(tr("device.type"), owner.small(tr("device.type.\(board.type.rawValue)"))),
                    formRow(tr("status"), statusText, button(tr("reconnect"), #selector(reconnect)))]
        if let forced {
            list.append(formRow(tr("port"), note: tr("port_forced", ["port": forced]), owner.small(forced)))
        } else {
            device = devicePopup(board.type, board.port, besides: board.id)
            list.append(formRow(tr("port"), note: portNote(board.type), refreshButton(#selector(refresh)), device))
        }
        if board.type == .diy {
            baud = popup(baudRates.map(String.init), selected: baudRates.firstIndex(of: board.baud) ?? 0)
            speed = popup(Speed.allCases.map(\.title), selected: Speed.allCases.firstIndex(of: board.speed) ?? 0)
            list.append(formRow(tr("baud_rate"), note: tr("baud_note"), baud))
            list.append(formRow(tr("speed"), note: tr("speed_note"), speed))
        }
        if board.type == .smc {
            lights = popup(lightPatterns.map { tr("lights.\($0)") }, selected: lightPatterns.firstIndex(of: board.lights) ?? 0)
            list.append(formRow(tr("lights"), note: tr("lights_note"), lights))
        }
        let next = ShortcutField(board.next) { [weak self] in self?.board.next = $0; self?.rebuild() }
        let previous = ShortcutField(board.previous) { [weak self] in self?.board.previous = $0; self?.rebuild() }
        for field in [next, previous] {
            field.clashes = { [weak self, weak field] shortcut in
                guard let self else { return false }
                let mine = [self.board.next, self.board.previous] + self.board.profiles.map(\.shortcut)
                return mine.contains { $0?.sameKeys(shortcut) == true && $0 != field?.value }
            }
        }
        for (title, field) in [(tr("next_profile"), next), (tr("previous_profile"), previous)] {
            let others = alsoUsedBy(field.value, besides: board.id, in: owner.draft.boards)
            let note = others.isEmpty ? nil : tr("shortcut.also_used", ["names": others.joined(separator: ", ")])
            list.append(formRow(title, note: note, field))
        }
        let remove = button(tr("device.remove"), #selector(removeBoard))
        remove.hasDestructiveAction = true
        var trailing = [button(tr("cancel"), #selector(close), key: "\u{1b}"), button(tr("save"), #selector(save), key: "\r")]
        if board.type != .smc { trailing.insert(button(tr("calibrate"), #selector(calibrate)), at: 0) }
        show(list, leading: [remove], trailing: trailing)
    }

    // Keeps what is typed and picked while the rows are made again.
    private func rebuild() {
        keep()
        DispatchQueue.main.async { [self] in build() }
    }

    private func keep() {
        board.name = name.stringValue
        if forced == nil { board.port = device.selectedItem?.representedObject as? String ?? board.port }
        if board.type == .diy {
            board.baud = baudRates[max(baud.indexOfSelectedItem, 0)]
            board.speed = Speed.allCases[max(speed.indexOfSelectedItem, 0)]
        }
        if board.type == .smc { board.lights = parseLightPattern(lightPatterns[max(lights.indexOfSelectedItem, 0)]) }
    }

    @objc private func refresh() { rebuild() }

    @objc private func reconnect() {
        if board.type.isMIDI { midi?.reconnect(board.id) } else { shared.requestReconnect(board.id) }
    }

    @objc private func save() {
        keep()
        let edited = board
        close()
        owner.changeAtOnce(edited.id) { board in
            board.name = edited.name.trimmingCharacters(in: .whitespaces).isEmpty ? tr("device.type.\(edited.type.rawValue)") : edited.name
            (board.port, board.baud, board.speed, board.lights) = (edited.port, edited.baud, edited.speed, edited.lights)
            (board.next, board.previous) = (edited.next, edited.previous)
        }
    }

    // Saves first, so the calibration reads the board where it now is.
    @objc private func calibrate() {
        let id = board.id
        save()
        owner.startWizard(id)
    }

    @objc private func removeBoard() {
        owner.confirm(tr("remove_named", ["name": board.name]), tr("device.remove_info"), in: window) { [self] in
            let id = board.id
            close()
            var setup = shared.config().setup
            setup.boards.removeAll { $0.id == id }
            owner.draft.boards.removeAll { $0.id == id }
            shared.setSetup(setup)
            if owner.wizard?.board == id { owner.calibrationWindow?.close() }
            startBoards()
            owner.refresh()
            owner.reloadDraft()
            owner.fitSettings()
        }
    }
}

// The profile shown on a board: its name and shortcut, edited in the draft that Apply saves.
final class ProfileDialog: Dialog {
    private let board: String
    private lazy var name = field("")

    init(owner: MenuBar, board: String) {
        self.board = board
        super.init(owner: owner)
        heading.stringValue = tr("profile")
        build()
    }

    private func build() {
        guard let index = owner.draft.index(of: board) else { return close() }
        let current = owner.draft.boards[index]
        name.stringValue = current.profile.name
        name.placeholderString = tr("profile_n", ["n": current.active + 1])
        let shortcut = ShortcutField(current.profile.shortcut) { [weak self] value in
            guard let self, let index = owner.draft.index(of: board) else { return }
            owner.draft.boards[index].profile.shortcut = value
            DispatchQueue.main.async { self.build() }
        }
        shortcut.clashes = { [weak self] value in
            guard let self, let board = owner.draft.board(board) else { return false }
            let others = [board.next, board.previous] + board.profiles.indices.filter { $0 != board.active }.map { board.profiles[$0].shortcut }
            return others.contains { $0?.sameKeys(value) == true }
        }
        let others = alsoUsedBy(current.profile.shortcut, besides: board, in: owner.draft.boards)
        let note = others.isEmpty ? nil : tr("shortcut.also_used", ["names": others.joined(separator: ", ")])
        show([formRow(tr("name"), name), formRow(tr("shortcut"), note: note, shortcut)],
             trailing: [button(tr("close"), #selector(done), key: "\r")])
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let index = owner.draft.index(of: board) else { return }
        owner.draft.boards[index].profile.name = name.stringValue
    }

    @objc private func done() {
        close()
        owner.reloadBoards()
        owner.fitSettings()
    }
}

extension MenuBar {
    @objc func addBoard() {
        AddBoardDialog(owner: self).window.makeFirstResponder(nil)
    }

    // From a board's gear on General, by its row, or from the Boards tab's menu.
    @objc func openBoardSettings(_ sender: Any) {
        let id = (sender as? NSMenuItem)?.representedObject as? String ?? (sender as? NSButton)?.identifier?.rawValue
        guard let board = id.flatMap(draft.board) else { return }
        _ = BoardSettingsDialog(owner: self, board: board)
    }

    @objc func editProfile() {
        guard let id = shownBoard else { return }
        _ = ProfileDialog(owner: self, board: id)
    }

    func closeSheet() {
        dialog?.close()
    }
}
#endif
