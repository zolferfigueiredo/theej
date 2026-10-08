#if canImport(AppKit)
import AppKit
import UniformTypeIdentifiers

private let otherApp = "other"  // what the Other… item of a control's menu carries in place of a job

// The Boards tab: one connected board at a time, its profile, and the board drawn or listed with what each
// control does, as WeeJ's Boards tab.
extension MenuBar {
    var connectedBoards: [Board] { draft.boards.filter { $0.enabled && shared.status($0.id).connected } }

    var shownIndex: Int? { shownBoard.flatMap { draft.index(of: $0) } }

    func reloadBoards() {
        stopRecording()  // else a recorder whose field is gone would keep taking every key
        listRows = [:]
        for view in boardsPage.arrangedSubviews { view.removeFromSuperview() }
        let boards = connectedBoards
        let board = boards.first { $0.id == shownBoard } ?? boards.first
        shownBoard = board?.id
        shared.setWatching(selectedTab == .boards && settingsWindow?.isVisible == true ? board?.id : nil)
        var views: [NSView]
        if let board {
            views = [boardToolbar(board, boards)] + (board.list ? listView(board) : drawView(board))
        } else {
            let text = NSTextField(wrappingLabelWithString: tr(draft.boards.isEmpty ? "boards.none" : "boards.none_connected"))
            text.textColor = .secondaryLabelColor
            text.alignment = .center
            let empty = NSStackView(views: [text])
            empty.orientation = .vertical
            empty.edgeInsets = NSEdgeInsets(top: 40, left: 0, bottom: 40, right: 0)
            if draft.boards.isEmpty { empty.addArrangedSubview(NSButton(title: tr("boards.set_up"), target: self, action: #selector(showGeneral))) }
            views = [empty]
        }
        if boardsFooter == nil {
            boardsFooter = saveFooter()
            boardsFooter?.widthAnchor.constraint(equalToConstant: boardsWidth).isActive = true
        }
        for view in views {
            boardsPage.addArrangedSubview(view)
            if !(view is NSBox) { view.widthAnchor.constraint(equalToConstant: boardsWidth).isActive = true }
        }
        boardsPage.addArrangedSubview(boardsFooter!)
        for (index, view) in views.enumerated() where view is NSBox && index + 1 < views.count {
            boardsPage.setCustomSpacing(16, after: view)
        }
    }

    @objc func showGeneral() { showTab(.general) }

    // [board] [profile] [⋯]  ...  [Draw | List]
    func boardToolbar(_ board: Board, _ boards: [Board]) -> NSStackView {
        let boardPicker = NSPopUpButton()
        for other in boards {
            boardPicker.menu?.addItem(withTitle: clipped(other.name, to: 30), action: nil, keyEquivalent: "")
            boardPicker.lastItem?.representedObject = other.id
        }
        boardPicker.selectItem(at: boards.firstIndex { $0.id == board.id } ?? 0)
        boardPicker.target = self
        boardPicker.action = #selector(pickShownBoard)
        boardPicker.setAccessibilityLabel(tr("boards.title"))
        let profilePicker = NSPopUpButton()
        for profile in board.profiles {
            // Not addItem(withTitle:), which drops a second profile with the same name.
            profilePicker.menu?.addItem(withTitle: clipped(profile.name, to: 30), action: nil, keyEquivalent: "")
        }
        profilePicker.selectItem(at: board.active)
        profilePicker.target = self
        profilePicker.action = #selector(pickDraftProfile)
        profilePicker.setAccessibilityLabel(tr("profile"))
        for picker in [boardPicker, profilePicker] { picker.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true }
        let more = NSButton(image: NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: tr("profile"))!,
                            target: self, action: #selector(showBoardMenu))
        more.isBordered = false
        more.toolTip = tr("profile")
        let view = NSSegmentedControl(labels: [tr("view.draw"), tr("view.list")], trackingMode: .selectOne,
                                      target: self, action: #selector(pickView))
        view.selectedSegment = board.list ? 1 : 0
        let bar = NSStackView()
        for item in [boardPicker, profilePicker, more] { bar.addView(item, in: .leading) }
        bar.addView(view, in: .trailing)
        return bar
    }

    @objc func pickShownBoard(_ sender: NSPopUpButton) {
        shownBoard = sender.selectedItem?.representedObject as? String
        reloadBoards()
        fitSettings()
    }

    // The profile shown is the one edited, and the one Apply makes active.
    @objc func pickDraftProfile(_ sender: NSPopUpButton) {
        guard let index = shownIndex else { return }
        draft.boards[index].active = sender.indexOfSelectedItem
        reloadBoards()
        fitSettings()
    }

    @objc func showBoardMenu(_ sender: NSButton) {
        guard let index = shownIndex else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(entry(tr("profile.edit"), #selector(editProfile), ""))
        menu.addItem(entry(tr("add_profile"), #selector(addProfile), ""))
        let remove = entry(tr("remove_profile"), #selector(removeProfile), "")
        remove.isEnabled = draft.boards[index].profiles.count > 1
        menu.addItem(remove)
        menu.addItem(.separator())
        let settings = entry(tr("boards.settings"), #selector(openBoardSettings), "")
        settings.representedObject = draft.boards[index].id
        menu.addItem(settings)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc func addProfile() {
        guard let index = shownIndex else { return }
        let count = draft.boards[index].profiles.count
        draft.boards[index].profiles.append(draft.boards[index].newProfile(tr("profile_n", ["n": count + 1])))
        draft.boards[index].active = count
        reloadBoards()
        fitSettings()
        editProfile()
    }

    @objc func removeProfile() {
        guard let index = shownIndex, draft.boards[index].profiles.count > 1 else { return }
        let name = draft.boards[index].profile.name.trimmingCharacters(in: .whitespaces)
        confirm(name.isEmpty ? tr("remove_this_profile") : tr("remove_named", ["name": name]), tr("remove_profile_info")) { [self] in
            guard let index = shownIndex else { return }
            draft.boards[index].profiles.remove(at: draft.boards[index].active)
            draft.boards[index].active = min(draft.boards[index].active, draft.boards[index].profiles.count - 1)
            reloadBoards()
            fitSettings()
        }
    }

    // Draw or List lands at once, as WeeJ's does.
    @objc func pickView(_ sender: NSSegmentedControl) {
        guard let id = shownBoard else { return }
        let list = sender.selectedSegment == 1
        changeAtOnce(id) { $0.list = list }
    }

    // MARK: Draw

    func pickedControl(_ board: Board) -> Int? {
        let valid = board.type == .smc ? Array(0..<board.controls.count) + smcButtonOrder : Array(board.controls.indices)
        guard let first = valid.first else { return nil }
        return picked[board.id].flatMap { valid.contains($0) ? $0 : nil } ?? first
    }

    func drawView(_ board: Board) -> [NSView] {
        let control = pickedControl(board)
        let drawing = BoardDrawing(board: board)
        drawing.values = liveValues[board.id] ?? []
        drawing.picked = control
        drawing.label = { [unowned self] in drawingLabel(board, $0) }
        drawing.assigned = { control in
            board.isButton(control) && !(board.buttonKey(control).flatMap { board.profile.buttons[$0] } ?? []).isEmpty
        }
        drawing.onPick = { [weak self] in self?.pickControl($0) }
        self.drawing = drawing
        // A group's box, as group() makes, with the drawing inside it.
        let card = NSBox()
        card.boxType = .custom
        card.cornerRadius = 10
        card.borderColor = .separatorColor
        card.fillColor = .quaternarySystemFill
        card.addSubview(drawing)
        NSLayoutConstraint.activate([
            drawing.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            drawing.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            drawing.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            drawing.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            card.widthAnchor.constraint(equalToConstant: boardsWidth),
        ])
        return [card, inspector(board, control), footnote(tr(board.type == .smc ? "smc.hint" : "board.hint"), width: boardsWidth)]
    }

    // The label under a drawn knob, fader or button: its first job or action and how many more it has. A
    // screen's short name says which screen but not whether brightness or contrast, so those keep their
    // title. An SMC-Mixer's buttons have no room for one, and show a dot instead.
    func drawingLabel(_ board: Board, _ control: Int) -> (text: String, more: Int, empty: Bool)? {
        if board.isButton(control) {
            guard board.type != .smc else { return nil }
            let actions = board.buttonKey(control).flatMap { board.profile.buttons[$0] } ?? []
            guard let first = actions.first else { return (tr("job.empty"), 0, true) }
            return (actionTitle(first, on: board), actions.count - 1, false)
        }
        let jobs = board.profile.jobs(of: control)
        guard let first = jobs.first else { return (tr("job.empty"), 0, true) }
        let short: String
        switch first {
        case .brightness, .contrast: short = title(first)
        default: short = shortTitle(first)
        }
        return (short, jobs.count - 1, false)
    }

    func inspector(_ board: Board, _ control: Int?) -> NSBox {
        let rows = NSStackView()
        let box = group(rows, width: boardsWidth)
        guard let control else {
            setRows(rows, [emptyRow(tr("board.empty"))])
            return box
        }
        let name = NSTextField(labelWithString: board.controlName(control))
        name.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let clear = NSButton(title: tr("clear"), target: self, action: #selector(clearControl))
        var list = [row([name], clear)]
        if !board.isButton(control) {
            clear.isEnabled = !board.profile.jobs(of: control).isEmpty
            list.append(potRow(board, control, handle: false))
        } else if let key = board.buttonKey(control) {
            clear.isEnabled = !(board.profile.buttons[key] ?? []).isEmpty
            list.append(buttonRow(board, key, named: false))
        } else {
            clear.isEnabled = false
            list.append(row([small(tr("needs_calibration"), .systemRed)]))
        }
        setRows(rows, list)
        return box
    }

    func pickControl(_ control: Int) {
        guard let id = shownBoard else { return }
        let focused = drawing != nil && settingsWindow?.firstResponder === drawing
        picked[id] = control
        reloadBoards()
        fitSettings()
        if focused { settingsWindow?.makeFirstResponder(drawing) }
    }

    @objc func clearControl() {
        guard let index = shownIndex, let control = pickedControl(draft.boards[index]) else { return }
        let board = draft.boards[index]
        if board.isButton(control) {
            if let key = board.buttonKey(control) { setActions([], key: key) }
        } else {
            setJobs([], control: control)
        }
        reloadBoards()
        fitSettings()
    }

    // MARK: List

    func listView(_ board: Board) -> [NSView] {
        var views: [NSView] = []
        for (kind, heading) in [(ControlKind.knob, tr("knobs")), (.fader, tr("list.faders"))] {
            let controls = board.controls.indices.filter { board.controls[$0].kind == kind }
            let rows = KnobList()
            rows.controls = controls
            rows.registerForDraggedTypes([.string])
            let box = group(rows, width: boardsWidth)
            setRows(rows, controls.isEmpty ? [emptyRow(tr("list.none"))] : controls.map { control in
                let row = potRow(board, control, handle: true)
                listRows[control] = row
                return row
            })
            views += [header(heading), box]
        }
        let rows = NSStackView()
        let box = group(rows, width: boardsWidth)
        let keys = board.buttonKeys
        setRows(rows, keys.isEmpty ? [emptyRow(tr("list.none"))] : keys.map { key in
            let row = buttonRow(board, key, named: true)
            if let control = board.control(ofKey: key) { listRows[control] = row }
            return row
        })
        return views + [header(tr("list.buttons")), box]
    }

    // A control's jobs in full, one under the other, each with its icon, and its menu. The grip drags them
    // onto another control of its kind.
    func potRow(_ board: Board, _ control: Int, handle: Bool) -> NSStackView {
        let popup = jobPopup(board, control)
        let jobs = board.profile.jobs(of: control)
        let list = itemList(jobs.isEmpty ? [(tr("job.empty"), nil)] : jobs.map { (title($0), jobIcon($0, tint: .labelColor)) },
                            opens: popup, empty: jobs.isEmpty)
        var leading: [NSView] = []
        if handle {
            let grip = KnobHandle(image: grip)
            grip.control = control
            grip.contentTintColor = .tertiaryLabelColor
            let note = board.controls[control].input == nil ? tr("needs_calibration") : nil
            leading = [grip, label(board.controlName(control), note: note, noteColor: .systemRed)]
        }
        let row = row(leading, list, popup)
        // The row centres the list without keeping its own padding round it, so a tall one needs it spelt out.
        list.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 8).isActive = true
        list.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -8).isActive = true
        return row
    }

    // A button's actions and its menu, with what sets an action that takes a setting under its name.
    func buttonRow(_ board: Board, _ key: Int, named: Bool) -> NSStackView {
        let popup = actionPopup(board, key)
        let actions = board.profile.buttons[key] ?? []
        let list = itemList(actions.isEmpty ? [(tr("job.empty"), nil)] : actions.map { (actionTitle($0, on: board), actionIcon($0)) },
                            opens: popup, empty: actions.isEmpty)
        let side = NSStackView()
        side.orientation = .vertical
        side.alignment = .leading
        side.spacing = 6
        if named { side.addArrangedSubview(NSTextField(labelWithString: board.controlName(board.control(ofKey: key) ?? key))) }
        for setting in settingViews(board, key) { side.addArrangedSubview(setting) }
        let row = row([side], list, popup)
        list.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 8).isActive = true
        list.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -8).isActive = true
        return row
    }

    // What sets the part of an action after its colon: a web address, keys to record or an app.
    func settingViews(_ board: Board, _ key: Int) -> [NSView] {
        (board.profile.buttons[key] ?? []).compactMap { action -> NSView? in
            let kind = actionKind(action)
            let setting = String(action.dropFirst(kind.count))
            let control: NSView
            switch kind {
            case "url:":
                let field = NSTextField(string: setting)
                field.placeholderString = "https://"
                field.identifier = NSUserInterfaceItemIdentifier("url:\(key)")
                field.delegate = self
                field.widthAnchor.constraint(equalToConstant: 220).isActive = true
                control = field
            case "keys:":
                let field = ShortcutField(pressedKeys(action), hotKey: false) { [weak self] shortcut in
                    self?.replaceAction(kind, key: key, with: shortcut.map(keysAction) ?? kind)
                }
                if recordNext == key {
                    recordNext = nil
                    DispatchQueue.main.async { [weak self] in self?.recordShortcut(field.button) }
                }
                control = field
            case "open:", "close:":
                let button = NSButton(title: setting.isEmpty ? tr("choose") : appName(setting), target: self, action: #selector(chooseButtonApp))
                button.tag = key
                button.identifier = NSUserInterfaceItemIdentifier(kind)
                control = button
            default:
                return nil
            }
            let line = NSStackView(views: [small(actionTitle(action, on: board)), control])
            line.spacing = 8
            return line
        }
    }

    // A url: field's typing, kept in the draft as it goes without rebuilding the rows under the cursor.
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, let id = field.identifier?.rawValue, id.hasPrefix("url:"),
              let key = Int(id.dropFirst(4)) else { return }
        replaceAction("url:", key: key, with: "url:" + field.stringValue, reload: false)
    }

    func replaceAction(_ kind: String, key: Int, with action: String, reload: Bool = true) {
        guard let index = shownIndex else { return }
        let actions = draft.boards[index].profile.buttons[key] ?? []
        setActions(actions.map { actionKind($0) == kind ? action : $0 }, key: key)
        if reload {
            reloadBoards()
            fitSettings()
        }
    }

    func setActions(_ actions: [String], key: Int) {
        guard let index = shownIndex else { return }
        draft.boards[index].profile.buttons[key] = actions.isEmpty ? nil : actions
    }

    func setJobs(_ jobs: [Target], control: Int) {
        guard let index = shownIndex else { return }
        var all = draft.boards[index].profile.jobs
        all += Array(repeating: [], count: max(0, control + 1 - all.count))
        all[control] = jobs
        draft.boards[index].profile.jobs = all
    }

    // A control's jobs onto another of its kind, in the profile shown, with the ones between shifting along.
    // The controls stay where they are.
    func moveJobs(from: Int, to: Int, among controls: [Int]) {
        guard let index = shownIndex, from != to, let start = controls.firstIndex(of: from),
              let end = controls.firstIndex(of: to) else { return }
        var jobs = controls.map { draft.boards[index].profile.jobs(of: $0) }
        jobs.insert(jobs.remove(at: start), at: end)
        for (control, moved) in zip(controls, jobs) { setJobs(moved, control: control) }
        reloadBoards()
        fitSettings()
    }

    // MARK: Menus

    // The jobs a control can have: the fixed ones, a pair per screen plugged in or already assigned, so Apply
    // cannot drop one that is unplugged, and the apps that make sound.
    func jobChoices(_ board: Board) -> (jobs: [Target], apps: Bool) {
        let assigned = board.profile.jobs.joined().compactMap { job -> Int? in
            switch job {
            case .brightness(let ordinal), .contrast(let ordinal): return ordinal + 1
            default: return nil
            }
        }.max() ?? 0
        let monitors: [Target] = (0..<max(externalDisplays().count, assigned)).flatMap { [.brightness($0), .contrast($0)] }
        // Apps that make sound: the ones playing now, the well-known ones that are installed, and any a
        // profile already uses, so Apply cannot drop one. Other… in each menu picks any app.
        let appsAvailable = if #available(macOS 14.2, *) { true } else { false }
        var apps: [Target] = []
        if appsAvailable {
            let known = knownAudioApps.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
            apps = draft.apps.union(known).union(appsPlayingSound()).subtracting([Bundle.main.bundleIdentifier ?? ""])
                .map(Target.app).sorted { title($0).localizedStandardCompare(title($1)) == .orderedAscending }
        }
        let fixed: [Target] = [.master, .microphone, .builtinBrightness, .builtinContrast, .nightShift, .builtinKeyboard,
                               .externalKeyboard, .zoom]
        return ((fixed + monitors).sorted { rank($0) < rank($1) } + apps, appsAvailable)
    }

    // A checklist, not a choice of one: the ticks are set from the control's jobs, not by the last click. The
    // popup itself shows only its arrows: a popup draws one line, and the jobs are listed beside it.
    func checklist(_ tag: Int, _ action: Selector, label: String) -> NSPopUpButton {
        let popup = NSPopUpButton()
        popup.isBordered = false
        (popup.cell as? NSPopUpButtonCell)?.altersStateOfSelectedItem = false
        popup.addItem(withTitle: tr("clear"))
        popup.menu?.addItem(.separator())
        popup.tag = tag
        popup.target = self
        popup.action = action
        popup.setAccessibilityLabel(label)
        let cell = popup.cell as? NSPopUpButtonCell
        cell?.usesItemFromMenu = false
        cell?.menuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        return popup
    }

    func jobPopup(_ board: Board, _ control: Int) -> NSPopUpButton {
        let popup = checklist(control, #selector(pickJob), label: board.controlName(control))
        let jobs = board.profile.jobs(of: control)
        let (choices, apps) = jobChoices(board)
        for (i, choice) in choices.enumerated() {
            if i == 0 || rank(choice) / 100 != rank(choices[i - 1]) / 100 {
                popup.menu?.addItem(.sectionHeader(title: section(choice)))
            }
            // Not addItem(withTitle:), which drops the Screen 1 under Brightness for the one under Contrast.
            let item = popup.menu?.addItem(withTitle: shortTitle(choice), action: nil, keyEquivalent: "")
            item?.representedObject = choice
            item?.image = jobIcon(choice)
            item?.state = jobs.contains(choice) ? .on : .off
        }
        if apps {
            popup.menu?.addItem(choices.contains { rank($0) == 600 } ? .separator() : .sectionHeader(title: tr("section.apps")))
            popup.menu?.addItem(withTitle: tr("other"), action: nil, keyEquivalent: "").representedObject = otherApp
        }
        popup.setAccessibilityValue(title(jobs))
        return popup
    }

    // A button's choices, in WeeJ's groups. Each kind of action that takes a setting is there once.
    func actionPopup(_ board: Board, _ key: Int) -> NSPopUpButton {
        let popup = checklist(key, #selector(pickAction), label: board.controlName(board.control(ofKey: key) ?? key))
        let kinds = Set((board.profile.buttons[key] ?? []).map(actionKind))
        let pots = board.controls.indices.filter { board.controls[$0].kind != .button }
        let groups: [(String, [String])] = [
            (tr("action.group.media"), ["media.playpause", "media.previous", "media.next", "volume.up", "volume.down", "mute.all"]),
            (tr("action.group.apps"), ["open:", "close:", "url:"]),
            (tr("action.group.system"), ["mute.mic", "keys:", "nightlight", "screens.off", "pc.lock", "pc.sleep"]),
            (appName, ["profile.previous", "profile.next"] + board.profiles.indices.map { "profile:\($0)" } + ["settings"]),
            (tr("action.group.fkeys"), functionKeys.map(\.action)),
            (tr("action.group.knobs"), pots.map { "mute:\($0)" }),
        ]
        for (heading, actions) in groups where !actions.isEmpty {
            popup.menu?.addItem(.sectionHeader(title: heading))
            for action in actions {
                let item = popup.menu?.addItem(withTitle: actionTitle(action, on: board), action: nil, keyEquivalent: "")
                item?.representedObject = action
                item?.image = actionIcon(action) ?? NSImage(size: NSSize(width: 16, height: 16))
                item?.state = kinds.contains(actionKind(action)) ? .on : .off
            }
        }
        return popup
    }

    @objc func pickJob(_ sender: NSPopUpButton) {
        guard let index = shownIndex else { return }
        let control = sender.tag
        guard sender.selectedItem?.representedObject as? String != otherApp else {
            chooseApp(forControl: control)
            return
        }
        // A click ticks a job or unticks it, and Clear unticks them all.
        var jobs = draft.boards[index].profile.jobs(of: control)
        if let job = sender.selectedItem?.representedObject as? Target {
            if let ticked = jobs.firstIndex(of: job) { jobs.remove(at: ticked) } else { jobs.append(job) }
        } else {
            jobs = []
        }
        setJobs(jobs, control: control)
        // The rows are rebuilt to list the jobs anew, once this popup's own click is over.
        DispatchQueue.main.async { [self] in
            reloadBoards()
            fitSettings()
        }
    }

    @objc func pickAction(_ sender: NSPopUpButton) {
        guard let index = shownIndex else { return }
        let key = sender.tag
        var actions = draft.boards[index].profile.buttons[key] ?? []
        if let action = sender.selectedItem?.representedObject as? String {
            let kind = actionKind(action)
            if actions.contains(where: { actionKind($0) == kind }) {
                actions.removeAll { actionKind($0) == kind }
            } else if kind == "open:" || kind == "close:" {
                return chooseApp(forButton: key, kind: kind)
            } else {
                actions.append(action)
                if kind == "keys:" { recordNext = key }
            }
        } else {
            actions = []
        }
        setActions(actions, key: key)
        DispatchQueue.main.async { [self] in
            reloadBoards()
            fitSettings()
        }
    }

    // Other… in a control's menu: any app on disk. The menus are rebuilt either way, to list the choice or to
    // put this one back on the job it had.
    func chooseApp(forControl control: Int) {
        pickApp { [self] id in
            guard let index = shownIndex else { return }
            let jobs = draft.boards[index].profile.jobs(of: control)
            if let id, id != Bundle.main.bundleIdentifier, !jobs.contains(.app(id)) { setJobs(jobs + [.app(id)], control: control) }
            reloadBoards()
        }
    }

    @objc func chooseButtonApp(_ sender: NSButton) {
        chooseApp(forButton: sender.tag, kind: sender.identifier?.rawValue ?? "open:")
    }

    // Open an app or Close an app: the app, which an action of the kind already there gives way to.
    func chooseApp(forButton key: Int, kind: String) {
        pickApp { [self] id in
            guard let index = shownIndex else { return }
            if let id {
                let actions = (draft.boards[index].profile.buttons[key] ?? []).filter { actionKind($0) != kind }
                setActions(actions + [kind + id], key: key)
            }
            reloadBoards()
            fitSettings()
        }
    }

    func pickApp(_ done: @escaping (String?) -> Void) {
        guard let window = settingsWindow else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = tr("choose")
        panel.beginSheetModal(for: window) { response in
            done(response == .OK ? panel.url.flatMap { Bundle(url: $0)?.bundleIdentifier } : nil)
        }
    }

    // A control's jobs or a button's actions in full, one under the other, each with its icon. A click on
    // them opens the menu. One label with the icons in its text: the row lays that out as it does any other.
    func itemList(_ items: [(String, NSImage?)], opens popup: NSPopUpButton, empty: Bool) -> NSTextField {
        let text = NSMutableAttributedString()
        for (name, icon) in items {
            if text.length > 0 { text.append(NSAttributedString(string: "\n")) }
            if let icon {
                let attachment = NSTextAttachment()
                attachment.image = icon
                attachment.bounds = NSRect(x: 0, y: -3, width: 16, height: 16)  // centred on the text, not on its baseline
                text.append(NSAttributedString(attachment: attachment))
                text.append(NSAttributedString(string: " "))
            }
            text.append(NSAttributedString(string: name))
        }
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        style.lineSpacing = 5
        text.addAttributes([.paragraphStyle: style, .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                            .foregroundColor: empty ? NSColor.secondaryLabelColor : NSColor.labelColor],
                           range: NSRange(location: 0, length: text.length))
        let list = NSTextField(labelWithAttributedString: text)
        // A label reports one line's height whatever it holds, so the row would not grow with the jobs.
        list.heightAnchor.constraint(equalToConstant: text.size().height.rounded(.up)).isActive = true
        list.addGestureRecognizer(NSClickGestureRecognizer(target: popup, action: #selector(NSPopUpButton.performClick(_:))))
        return list
    }

    // MARK: The board moving

    func showValues(_ id: String, _ values: [Int]) {
        liveValues[id] = values
        if id == shownBoard { drawing?.values = values }
    }

    // A control moved or was pressed: it lights for a second, and in Draw it is picked, unless something is
    // being typed or recorded.
    func touched(_ id: String, _ control: Int) {
        guard id == shownBoard, settingsWindow?.isVisible == true, selectedTab == .boards, let board = draft.board(id) else { return }
        if board.list {
            guard let row = listRows[control] else { return }
            row.wantsLayer = true
            row.layer?.cornerRadius = 10
            row.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { row.layer?.backgroundColor = nil }
            return
        }
        let typing = settingsWindow?.firstResponder is NSText
        if picked[id] != control, recorder == nil, sheet == nil, !typing { pickControl(control) }
        drawing?.light(control)
    }

    func pressed(_ id: String, _ key: Int) {
        if let control = draft.board(id)?.control(ofKey: key) { touched(id, control) }
    }
}
#endif
