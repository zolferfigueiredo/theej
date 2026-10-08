#if canImport(AppKit)
import AppKit
import UniformTypeIdentifiers

private let otherApp = "other"  // what the Other… item of a control's menu carries in place of a job
private let inspectorWidth: CGFloat = 300

// The Boards tab: one connected board at a time, its profile, and the board drawn or listed with what each
// control does, as WeeJ's Boards tab.
extension MenuBar {
    var connectedBoards: [Board] { draft.boards.filter { $0.enabled && shared.status($0.id).connected } }

    var shownIndex: Int? { shownBoard.flatMap { draft.index(of: $0) } }

    func reloadBoards() {
        stopRecordingOnPages()
        listRows = [:]
        let scrolled = scrollers.mapValues { $0.contentView.bounds.origin.y }
        scrollers = [:]
        for view in boardsPage.arrangedSubviews { view.removeFromSuperview() }
        let boards = connectedBoards
        let board = boards.first { $0.id == shownBoard } ?? boards.first
        shownBoard = board?.id
        shared.setWatching(selectedTab == .boards && settingsWindow?.isVisible == true ? board?.id : nil)
        if let board { jobMenu = jobChoices(board) }
        var views: [NSView]
        if let board {
            let note = importNote.flatMap { $0.board == board.id ? [footnote($0.text, width: boardsWidth)] : nil } ?? []
            views = [boardToolbar(board, boards)] + note + (board.list ? listView(board) : drawView(board))
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
        boardsPage.layoutSubtreeIfNeeded()
        for (key, scroll) in scrollers {
            if let y = scrolled[key] {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
            } else if let ticked = firstTicked(in: scroll.documentView) {
                // A list opened fresh starts on the first thing its control already does.
                scroll.contentView.scroll(to: NSPoint(x: 0, y: max(ticked.convert(ticked.bounds, to: scroll.contentView).minY - 40, 0)))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
    }

    private func firstTicked(in view: NSView?) -> NSView? {
        if let box = view as? NSButton, box.state == .on, box.action == #selector(tickJob) || box.action == #selector(tickAction) {
            return box
        }
        return view?.subviews.lazy.compactMap { self.firstTicked(in: $0) }.first
    }

    // Rows that scroll, as tall as the view they are in lets them be.
    func scroller(_ rows: NSStackView, key: String) -> NSScrollView {
        rows.orientation = .vertical
        rows.spacing = 0
        rows.alignment = .trailing
        rows.translatesAutoresizingMaskIntoConstraints = false
        rows.setHuggingPriority(.defaultHigh + 1, for: .vertical)
        let scroll = NSScrollView()
        scroll.contentView = TopClipView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = rows
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            rows.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            rows.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        scrollers[key] = scroll
        return scroll
    }

    // A group as group() makes, whose rows scroll past maxHeight.
    func scrollingGroup(_ rows: NSStackView, width: CGFloat, maxHeight: CGFloat, key: String) -> NSBox {
        let scroll = scroller(rows, key: key)
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 10
        box.borderColor = .separatorColor
        box.fillColor = .quaternarySystemFill
        box.addSubview(scroll)
        let fit = scroll.heightAnchor.constraint(equalTo: rows.heightAnchor)
        fit.priority = .defaultHigh - 1
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: box.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            scroll.heightAnchor.constraint(lessThanOrEqualToConstant: maxHeight),
            fit,
            box.widthAnchor.constraint(equalToConstant: width),
        ])
        return box
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
        if !board.list, board.type != .smc, !board.controls.isEmpty {
            let arrange = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: tr("board.arrange"))!,
                                   target: self, action: #selector(toggleArrange))
            arrange.setButtonType(.pushOnPushOff)
            arrange.state = arranging.contains(board.id) ? .on : .off
            arrange.toolTip = tr("board.arrange")
            bar.addView(arrange, in: .trailing)
        }
        bar.addView(view, in: .trailing)
        return bar
    }

    @objc func pickShownBoard(_ sender: NSPopUpButton) {
        shownBoard = sender.selectedItem?.representedObject as? String
        importNote = nil
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
        menu.addItem(entry(tr("profile.import"), #selector(importProfile), ""))
        menu.addItem(entry(tr("profile.export"), #selector(exportProfile), ""))
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

    // A WeeJ or TheeJ profile file, or deej's config, as a new profile of the board shown, which Apply saves.
    @objc func importProfile() {
        guard let id = shownBoard, let window = settingsWindow else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .yaml]
        panel.beginSheetModal(for: window) { [self] response in
            guard response == .OK, let url = panel.url, let index = draft.index(of: id) else { return }
            shownBoard = id
            defer {
                reloadBoards()
                fitSettings()
            }
            guard let data = try? Data(contentsOf: url), let imported = importedProfile(data, for: draft.boards[index]) else {
                importNote = (id, tr("import_failed"))
                return
            }
            var profile = imported.profile
            let count = draft.boards[index].profiles.count
            if profile.name.trimmingCharacters(in: .whitespaces).isEmpty { profile.name = tr("profile_n", ["n": count + 1]) }
            draft.boards[index].profiles.append(profile)
            draft.boards[index].active = count
            importNote = imported.skipped.isEmpty ? nil : (id, tr("import_skipped", ["items": imported.skipped.joined(separator: ", ")]))
        }
    }

    // The profile shown, as Settings has it, Apply or not.
    @objc func exportProfile() {
        guard let index = shownIndex, let window = settingsWindow else { return }
        let board = draft.boards[index]
        guard let data = profileFile(board.profile, of: board) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        // Finder shows a colon in a file name as a slash, and a slash can't be in one.
        panel.nameFieldStringValue = "\(board.name) - \(board.profile.name)".components(separatedBy: CharacterSet(charactersIn: "/:"))
            .joined(separator: "_") + ".json"
        panel.beginSheetModal(for: window) { [self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url)
            } catch {
                log("Could not export the profile: \(error.localizedDescription)", for: board.id)
                importNote = (board.id, tr("profile.export_failed"))
                reloadBoards()
                fitSettings()
            }
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
        // From the draft as it is now, so a tick in the inspector shows without the tab being built again.
        drawing.label = { [unowned self] control in draft.board(board.id).flatMap { drawingLabel($0, control) } }
        drawing.assigned = { [unowned self] control in
            guard let board = draft.board(board.id) else { return false }
            return board.isButton(control) && !(board.buttonKey(control).flatMap { board.profile.buttons[$0] } ?? []).isEmpty
        }
        drawing.onPick = { [weak self] in self?.pickControl($0) }
        self.drawing = drawing
        // A group's box, as group() makes, with the drawing in its middle.
        let card = NSBox()
        card.boxType = .custom
        card.cornerRadius = 10
        card.borderColor = .separatorColor
        card.fillColor = .quaternarySystemFill
        card.addSubview(drawing)
        let fit = card.heightAnchor.constraint(equalTo: drawing.heightAnchor, constant: 24)
        fit.priority = .defaultLow
        NSLayoutConstraint.activate([
            drawing.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            drawing.topAnchor.constraint(greaterThanOrEqualTo: card.topAnchor, constant: 12),
            drawing.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            drawing.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            card.widthAnchor.constraint(equalToConstant: boardsWidth - inspectorWidth - 16),
            card.heightAnchor.constraint(greaterThanOrEqualToConstant: 360),
            fit,
        ])
        let inspector = inspector(board, control)
        let pair = NSStackView(views: [card, inspector])
        pair.alignment = .top
        pair.spacing = 16
        inspector.heightAnchor.constraint(equalTo: card.heightAnchor).isActive = true
        return [pair, footnote(tr(board.type == .smc ? "smc.hint" : "board.hint"), width: boardsWidth)]
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

    @objc func toggleArrange() {
        guard let id = shownBoard else { return }
        if arranging.remove(id) == nil { arranging.insert(id) }
        reloadBoards()
        fitSettings()
    }

    @objc func moveControl(_ sender: NSButton) {
        guard let index = shownIndex, let control = pickedControl(draft.boards[index]) else { return }
        draft.boards[index].move(control, Board.Move.allCases[sender.tag])
        reloadBoards()
        fitSettings()
    }

    // The picked control's name and Clear, the arrows while the board is arranged, then everything it can do,
    // ticked where it does it.
    func inspector(_ board: Board, _ control: Int?) -> NSBox {
        let content = NSStackView()
        let box = group(content, width: inspectorWidth)
        guard let control else {
            setRows(content, [emptyRow(tr("board.empty"))])
            return box
        }
        let name = NSTextField(labelWithString: board.controlName(control))
        name.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let clear = NSButton(title: tr("clear"), target: self, action: #selector(clearControl))
        inspectorClear = clear
        var rows: [NSView] = [row([name], clear)]
        if arranging.contains(board.id), board.type != .smc { rows.append(arrowKeys(board, control)) }
        let picks = NSStackView()
        if !board.isButton(control) {
            clear.isEnabled = !board.profile.jobs(of: control).isEmpty
            jobPicks(board, control, into: picks)
        } else if let key = board.buttonKey(control) {
            clear.isEnabled = !(board.profile.buttons[key] ?? []).isEmpty
            actionPicks(board, key, into: picks)
        } else {
            clear.isEnabled = false
            picks.addArrangedSubview(row([small(tr("needs_calibration"), .systemRed)]))
        }
        let list = scroller(picks, key: "inspector-\(board.id)-\(control)")
        for view in picks.arrangedSubviews { view.widthAnchor.constraint(equalTo: picks.widthAnchor).isActive = true }
        rows.append(list)
        setRows(content, rows)
        // The list takes the height the drawing leaves, and scrolls.
        content.distribution = .fill
        for case let view as NSStackView in rows.dropLast() { view.setHuggingPriority(.defaultHigh, for: .vertical) }
        list.setContentHuggingPriority(.defaultLow - 1, for: .vertical)
        return box
    }

    // ↑ over ← ↓ →, as on a keyboard.
    func arrowKeys(_ board: Board, _ control: Int) -> NSStackView {
        func arrow(_ move: Board.Move) -> NSButton {
            let arrow = NSButton(image: NSImage(systemSymbolName: "arrow.\(move)", accessibilityDescription: tr("board.\(move)"))!,
                                 target: self, action: #selector(moveControl))
            arrow.tag = Board.Move.allCases.firstIndex(of: move)!
            arrow.toolTip = tr("board.\(move)")
            arrow.isEnabled = board.canMove(control, move)
            arrow.widthAnchor.constraint(equalToConstant: 40).isActive = true
            return arrow
        }
        let keys = NSGridView(views: [[NSGridCell.emptyContentView, arrow(.up), NSGridCell.emptyContentView],
                                      [arrow(.left), arrow(.down), arrow(.right)]])
        keys.rowSpacing = 2
        keys.columnSpacing = 2
        let row = NSStackView()
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        row.addView(keys, in: .center)
        return row
    }

    // A tick, with its icon before its name, as WeeJ's inspector lists them.
    func pick(_ title: String, icon: NSImage?, on: Bool, action: Selector, into picks: NSStackView) -> NSButton {
        let text = NSMutableAttributedString()
        if let icon {
            let attachment = NSTextAttachment()
            attachment.image = icon
            attachment.bounds = NSRect(x: 0, y: -3, width: 16, height: 16)  // centred on the text, not on its baseline
            text.append(NSAttributedString(attachment: attachment))
            text.append(NSAttributedString(string: " "))
        }
        text.append(NSAttributedString(string: title))
        text.addAttributes([.font: NSFont.systemFont(ofSize: NSFont.systemFontSize), .foregroundColor: NSColor.labelColor],
                           range: NSRange(location: 0, length: text.length))
        let box = NSButton(checkboxWithTitle: title, target: self, action: action)
        box.attributedTitle = text
        box.state = on ? .on : .off
        box.lineBreakMode = .byTruncatingTail
        box.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let line = NSStackView(views: [box])
        line.edgeInsets = NSEdgeInsets(top: 3, left: 12, bottom: 3, right: 12)
        picks.addArrangedSubview(line)
        return box
    }

    func pickHead(_ title: String, into picks: NSStackView) {
        let line = NSStackView(views: [small(title)])
        line.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 2, right: 12)
        picks.addArrangedSubview(line)
    }

    // The jobs of the control's menu, by section, then Other… for any app.
    func jobPicks(_ board: Board, _ control: Int, into picks: NSStackView) {
        let jobs = board.profile.jobs(of: control)
        let (choices, apps) = jobMenu
        for (i, choice) in choices.enumerated() {
            if i == 0 || rank(choice) / 100 != rank(choices[i - 1]) / 100 { pickHead(section(choice), into: picks) }
            pick(shortTitle(choice), icon: jobIcon(choice), on: jobs.contains(choice), action: #selector(tickJob), into: picks).tag = i
        }
        guard apps else { return }
        if !choices.contains(where: { rank($0) == 600 }) { pickHead(tr("section.apps"), into: picks) }
        let other = NSButton(title: tr("other"), target: self, action: #selector(pickOtherApp))
        let line = NSStackView(views: [other])
        line.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 10, right: 12)
        picks.addArrangedSubview(line)
    }

    // The button's menu, ticked in place, with what sets an action that takes a setting under its tick.
    func actionPicks(_ board: Board, _ key: Int, into picks: NSStackView) {
        let actions = board.profile.buttons[key] ?? []
        let kinds = Set(actions.map(actionKind))
        for (heading, group) in actionGroups(board) where !group.isEmpty {
            pickHead(heading, into: picks)
            for action in group {
                let kind = actionKind(action)
                let box = pick(actionTitle(action, on: board), icon: actionIcon(action), on: kinds.contains(kind), action: #selector(tickAction),
                               into: picks)
                box.tag = key
                box.identifier = NSUserInterfaceItemIdentifier(action)
                guard let current = actions.first(where: { actionKind($0) == kind }), let setting = settingControl(board, key, current) else { continue }
                let line = NSStackView(views: [setting])
                line.edgeInsets = NSEdgeInsets(top: 0, left: 34, bottom: 6, right: 12)
                picks.addArrangedSubview(line)
            }
        }
    }

    @objc func tickJob(_ sender: NSButton) {
        guard let index = shownIndex, let control = pickedControl(draft.boards[index]), jobMenu.jobs.indices.contains(sender.tag) else { return }
        let job = jobMenu.jobs[sender.tag]
        var jobs = draft.boards[index].profile.jobs(of: control)
        jobs.removeAll { $0 == job }
        if sender.state == .on { jobs.append(job) }
        setJobs(jobs, control: control)
        inspectorChanged()
    }

    @objc func tickAction(_ sender: NSButton) {
        guard let index = shownIndex, let action = sender.identifier?.rawValue else { return }
        let key = sender.tag
        let kind = actionKind(action)
        var actions = draft.boards[index].profile.buttons[key] ?? []
        if sender.state == .off {
            actions.removeAll { actionKind($0) == kind }
        } else if kind == "open:" || kind == "close:" {
            sender.state = .off  // until an app is chosen
            return chooseApp(forButton: key, kind: kind)
        } else {
            actions.append(action)
            if kind == "keys:" { recordNext = key }
        }
        setActions(actions, key: key)
        guard settingActions.contains(kind) else { return inspectorChanged() }
        // Its setting shows under it, once this click is over.
        DispatchQueue.main.async { [self] in
            reloadBoards()
            fitSettings()
        }
    }

    @objc func pickOtherApp() {
        guard let index = shownIndex, let control = pickedControl(draft.boards[index]) else { return }
        chooseApp(forControl: control)
    }

    // A tick changed the draft: the drawing's labels and Clear follow, and the list stays as it is.
    func inspectorChanged() {
        drawing?.needsDisplay = true
        guard let index = shownIndex, let control = pickedControl(draft.boards[index]) else { return }
        let board = draft.boards[index]
        inspectorClear?.isEnabled = board.isButton(control)
            ? !(board.buttonKey(control).flatMap { board.profile.buttons[$0] } ?? []).isEmpty
            : !board.profile.jobs(of: control).isEmpty
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

    // Knobs, faders and buttons side by side, each scrolling past about ten rows, as WeeJ's List.
    func listView(_ board: Board) -> [NSView] {
        let width = (boardsWidth - 32) / 3
        func column(_ heading: String, _ box: NSBox) -> NSStackView {
            let head = header(heading)
            head.widthAnchor.constraint(equalToConstant: width).isActive = true
            let column = NSStackView(views: [head, box])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 8
            return column
        }
        var columns: [NSView] = []
        for (kind, heading) in [(ControlKind.knob, tr("knobs")), (.fader, tr("list.faders"))] {
            let controls = board.controls.indices.filter { board.controls[$0].kind == kind }
            let rows = KnobList()
            rows.controls = controls
            rows.registerForDraggedTypes([.string])
            let box = scrollingGroup(rows, width: width, maxHeight: 480, key: "list-\(board.id)-\(kind)")
            setRows(rows, controls.isEmpty ? [emptyRow(tr("list.none"))] : controls.map { control in
                let row = potRow(board, control, width: width)
                listRows[control] = row
                return row
            })
            columns.append(column(heading, box))
        }
        let rows = NSStackView()
        let box = scrollingGroup(rows, width: width, maxHeight: 480, key: "list-\(board.id)-button")
        let keys = board.buttonKeys
        setRows(rows, keys.isEmpty ? [emptyRow(tr("list.none"))] : keys.map { key in
            let row = buttonRow(board, key, width: width)
            if let control = board.control(ofKey: key) { listRows[control] = row }
            return row
        })
        columns.append(column(tr("list.buttons"), box))
        let list = NSStackView(views: columns)
        list.alignment = .top
        list.spacing = 16
        list.setHuggingPriority(.init(1), for: .vertical)  // else it stretches the shorter columns to the tallest
        return [list]
    }

    // A control's jobs in full, one under the other, each with its icon, and its menu. The grip drags them
    // onto another control of its kind.
    func potRow(_ board: Board, _ control: Int, width: CGFloat) -> NSStackView {
        let popup = jobPopup(board, control)
        let jobs = board.profile.jobs(of: control)
        let grip = KnobHandle(image: grip)
        grip.control = control
        grip.contentTintColor = .tertiaryLabelColor
        let note = board.controls[control].input == nil ? tr("needs_calibration") : nil
        let name = label(board.controlName(control), note: note, noteColor: .systemRed)
        let room = width - 24 - grip.fittingSize.width - name.fittingSize.width - popup.fittingSize.width - 3 * 8
        let list = itemList(jobs.isEmpty ? [(tr("job.empty"), nil)] : jobs.map { (title($0), jobIcon($0, tint: .labelColor)) },
                            opens: popup, empty: jobs.isEmpty, width: room)
        let row = row([grip, name], list, popup)
        // The row centres the list without keeping its own padding round it, so a tall one needs it spelt out.
        list.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 8).isActive = true
        list.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -8).isActive = true
        return row
    }

    // A button's actions and its menu, with what sets an action that takes a setting under them.
    func buttonRow(_ board: Board, _ key: Int, width: CGFloat) -> NSStackView {
        let popup = actionPopup(board, key)
        let actions = board.profile.buttons[key] ?? []
        let name = NSTextField(labelWithString: board.controlName(board.control(ofKey: key) ?? key))
        let room = width - 24 - name.fittingSize.width - popup.fittingSize.width - 2 * 8
        let list = itemList(actions.isEmpty ? [(tr("job.empty"), nil)] : actions.map { (actionTitle($0, on: board), actionIcon($0)) },
                            opens: popup, empty: actions.isEmpty, width: room)
        let top = row([name], list, popup)
        list.topAnchor.constraint(greaterThanOrEqualTo: top.topAnchor, constant: 8).isActive = true
        list.bottomAnchor.constraint(lessThanOrEqualTo: top.bottomAnchor, constant: -8).isActive = true
        let row = NSStackView(views: [top])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 4
        top.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        for action in actions {
            guard let setting = settingControl(board, key, action) else { continue }
            let line = NSStackView(views: [small(actionTitle(action, on: board)), setting])
            line.orientation = .vertical
            line.alignment = .leading
            line.spacing = 4
            line.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 8, right: 12)
            row.addArrangedSubview(line)
        }
        return row
    }

    // What sets the part of an action after its colon: a web address, keys to record or an app.
    func settingControl(_ board: Board, _ key: Int, _ action: String) -> NSView? {
        let kind = actionKind(action)
        let setting = String(action.dropFirst(kind.count))
        switch kind {
        case "url:":
            let field = NSTextField(string: setting)
            field.placeholderString = "https://"
            field.identifier = NSUserInterfaceItemIdentifier("url:\(key)")
            field.delegate = self
            field.widthAnchor.constraint(equalToConstant: 220).isActive = true
            return field
        case "keys:":
            let field = ShortcutField(pressedKeys(action), hotKey: false) { [weak self] shortcut in
                self?.replaceAction(kind, key: key, with: shortcut.map(keysAction) ?? kind)
            }
            if recordNext == key {
                recordNext = nil
                DispatchQueue.main.async { [weak self] in self?.recordShortcut(field.button) }
            }
            return field
        case "open:", "close:":
            let button = NSButton(title: setting.isEmpty ? tr("choose") : appName(setting), target: self, action: #selector(chooseButtonApp))
            button.tag = key
            button.identifier = NSUserInterfaceItemIdentifier(kind)
            return button
        default:
            return nil
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
        let (choices, apps) = jobMenu
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
    func actionGroups(_ board: Board) -> [(String, [String])] {
        let pots = board.controls.indices.filter { board.controls[$0].kind != .button }
        return [
            (tr("action.group.media"), ["media.playpause", "media.previous", "media.next", "volume.up", "volume.down", "mute.all"]),
            (tr("action.group.apps"), ["open:", "close:", "url:"]),
            (tr("action.group.system"), ["mute.mic", "keys:", "nightlight", "screens.off", "pc.lock", "pc.sleep"]),
            (appName, ["profile.previous", "profile.next"] + board.profiles.indices.map { "profile:\($0)" }
                + ["settings", "lights.next", "lights.previous", "lights.on", "lights.off"]),
            (tr("action.group.fkeys"), functionKeys.map(\.action)),
            (tr("action.group.knobs"), pots.map { "mute:\($0)" }),
        ]
    }

    func actionPopup(_ board: Board, _ key: Int) -> NSPopUpButton {
        let popup = checklist(key, #selector(pickAction), label: board.controlName(board.control(ofKey: key) ?? key))
        let kinds = Set((board.profile.buttons[key] ?? []).map(actionKind))
        for (heading, actions) in actionGroups(board) where !actions.isEmpty {
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
    func itemList(_ items: [(String, NSImage?)], opens popup: NSPopUpButton, empty: Bool, width: CGFloat) -> NSTextField {
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
        // A long one wraps within width, the room its column leaves it. Sized by hand: a label works out the
        // size of wrapped text with attachments too small, and cuts its end off.
        let list = NSTextField(wrappingLabelWithString: "")
        list.attributedStringValue = text
        let size = text.boundingRect(with: NSSize(width: max(width, 40) - 4, height: .greatestFiniteMagnitude),
                                     options: [.usesLineFragmentOrigin, .usesFontLeading]).size
        list.widthAnchor.constraint(equalToConstant: size.width.rounded(.up) + 4).isActive = true
        list.heightAnchor.constraint(equalToConstant: size.height.rounded(.up)).isActive = true
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
            row.scrollToVisible(row.bounds)
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
