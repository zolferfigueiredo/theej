import AppKit
import Carbon.HIToolbox

extension MenuBar {
    // A second click keeps unsaved edits in an open window.
    @objc func openSettings() {
        if settingsWindow?.isVisible != true {
            draft = shared.config().setup
            calibrateOnSave.state = prefs.object(forKey: "calibrateOnSave") as? Bool == false ? .off : .on
        }
        showSettings()
        settingsWindow?.makeFirstResponder(nil)  // else the name field opens with its text selected
    }

    // Laid out as System Settings groups. Built once; after that only the rows and values change.
    func showSettings() {
        if let window = settingsWindow {
            reloadDraft()
            fit(window)
        } else {
            setUpEdit(profileEdit, "Add a profile", "Remove this profile", #selector(editProfiles))
            setUpEdit(knobEdit, "Add a knob", "Remove the last knob", #selector(editKnobs))
            profilePicker.target = self
            profilePicker.action = #selector(pickDraftProfile)
            profileName.delegate = self
            profileName.widthAnchor.constraint(equalToConstant: 180).isActive = true
            shortcutButton.target = self
            shortcutButton.action = #selector(recordShortcut)
            shortcutButton.toolTip = "Use ⌘ or ⌃ with a key. Delete clears it, Escape cancels."
            shortcutButton.widthAnchor.constraint(equalToConstant: 180).isActive = true
            removeShortcutButton.isBordered = false
            removeShortcutButton.contentTintColor = .secondaryLabelColor
            removeShortcutButton.toolTip = "Remove shortcut"
            removeShortcutButton.target = self
            removeShortcutButton.action = #selector(removeShortcut)
            let profileGroup = group(profileRows)
            setRows(profileRows, [row([NSTextField(labelWithString: "Name")], profileName),
                                  row([NSTextField(labelWithString: "Shortcut")], removeShortcutButton, shortcutButton)])
            let knobGroup = group(knobRows)

            let caption = NSTextField(labelWithString: "Choose what each knob does in this profile.")
            caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            caption.textColor = .secondaryLabelColor
            for box in [invertKnobs, showName, hideIcon, iconPicker] {
                box.target = self
                box.action = #selector(toggleOption)
            }
            for style in IconStyle.allCases {
                iconPicker.addItem(withTitle: style.title)
                iconPicker.lastItem?.image = makeIcon(style, parked: false, side: 16)
            }
            let iconRow = NSStackView(views: [iconLabel, iconPicker])
            let hint = NSTextField(labelWithString: "Open \(appName) again to get back here.")
            hint.font = caption.font
            hint.textColor = .secondaryLabelColor
            let hintRow = NSStackView(views: [hint])
            hintRow.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)  // under the checkbox title
            let save = NSButton(title: "Save", target: self, action: #selector(saveSettings))
            save.keyEquivalent = "\r"
            let footer = NSStackView()
            footer.addView(calibrateOnSave, in: .leading)
            footer.addView(save, in: .trailing)

            let profileHeader = header("Profile", [profilePicker], profileEdit)
            let knobHeader = header("Knobs", [], knobEdit)
            let content = NSStackView(views: [profileHeader, profileGroup, knobHeader, knobGroup, caption,
                                              invertKnobs, hideIcon, hintRow, showName, iconRow, footer])
            content.orientation = .vertical
            content.alignment = .leading
            content.spacing = 8
            for view in [profileGroup, caption, iconRow] { content.setCustomSpacing(20, after: view) }
            content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
            content.setHuggingPriority(.defaultHigh, for: .horizontal)  // else fittingSize drops the right inset
            for view in [profileHeader, knobHeader, footer] {
                view.widthAnchor.constraint(equalTo: knobGroup.widthAnchor).isActive = true
            }
            reloadDraft()
            let window = makeWindow("\(appName) Settings", content)
            // Else closing the window mid-recording would leave every shortcut off.
            NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window,
                                                   queue: .main) { [weak self] _ in self?.stopRecording() }
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                   queue: .main) { _ in NSApp.setActivationPolicy(.accessory) }
            settingsWindow = window
        }
        // A regular app while Settings is open, so Cmd+Tab can switch back to it.
        NSApp.setActivationPolicy(.regular)
        present(settingsWindow!)
    }

    func setUpEdit(_ control: NSSegmentedControl, _ add: String, _ remove: String, _ action: Selector) {
        control.segmentCount = 2
        control.trackingMode = .momentary
        control.setImage(NSImage(systemSymbolName: "plus", accessibilityDescription: add), forSegment: 0)
        control.setImage(NSImage(systemSymbolName: "minus", accessibilityDescription: remove), forSegment: 1)
        control.setToolTip(add, forSegment: 0)
        control.setToolTip(remove, forSegment: 1)
        control.target = self
        control.action = action
    }

    func header(_ title: String, _ controls: [NSView], _ edit: NSSegmentedControl) -> NSStackView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let header = NSStackView()
        for view in [heading] + controls { header.addView(view, in: .leading) }
        header.addView(edit, in: .trailing)
        return header
    }

    func group(_ rows: NSStackView) -> NSBox {
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
            box.widthAnchor.constraint(equalToConstant: 420),
        ])
        return box
    }

    func row(_ leading: [NSView], _ trailing: NSView...) -> NSStackView {
        let row = NSStackView()
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        for view in leading { row.addView(view, in: .leading) }
        for view in trailing { row.addView(view, in: .trailing) }
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

    // Rebuilt on every change, which keeps each popup's tag equal to its knob index.
    func reloadDraft() {
        stopRecording()
        profilePicker.removeAllItems()
        for profile in draft.profiles {
            // Not addItem(withTitle:), which drops a second profile with the same name.
            profilePicker.menu?.addItem(withTitle: profile.name, action: nil, keyEquivalent: "")
        }
        profilePicker.selectItem(at: draft.active)
        profileName.stringValue = draft.profile.name
        profileEdit.setEnabled(draft.profiles.count > 1, forSegment: 1)
        invertKnobs.state = draft.invert ? .on : .off
        showName.state = draft.showName ? .on : .off
        hideIcon.state = draft.hideIcon ? .on : .off
        iconPicker.selectItem(at: IconStyle.allCases.firstIndex(of: draft.icon) ?? 0)
        showName.isEnabled = !draft.hideIcon
        iconPicker.isEnabled = !draft.hideIcon
        iconLabel.textColor = draft.hideIcon ? .disabledControlTextColor : .labelColor

        let assigned = draft.profile.targets.compactMap { target -> Int? in
            switch target {
            case .brightness(let ordinal)?, .contrast(let ordinal)?: return ordinal + 1
            default: return nil
            }
        }.max() ?? 0
        // Includes an assigned monitor that is unplugged right now, so Save cannot drop it.
        let monitors: [Target] = (0..<max(2, externalDisplays().count, assigned))
            .flatMap { [.brightness($0), .contrast($0)] }
        let choices = ([Target.master, .microphone, .builtinBrightness, .builtinContrast, .nightShift,
                        .builtinKeyboard, .externalKeyboard] + monitors).sorted { rank($0) < rank($1) }

        var rows = draft.columns.indices.map { index -> NSStackView in
            let popup = NSPopUpButton()
            popup.isBordered = false
            popup.addItem(withTitle: title(nil))
            for (i, choice) in choices.enumerated() {
                if i == 0 || rank(choice) / 100 != rank(choices[i - 1]) / 100 { popup.menu?.addItem(.separator()) }
                popup.addItem(withTitle: title(choice))
                popup.lastItem?.representedObject = choice
                if choice == draft.profile.target(index) { popup.select(popup.lastItem) }
            }
            popup.tag = index
            popup.target = self
            popup.action = #selector(pick)
            popup.setAccessibilityLabel("Knob \(letter(index))")
            var leading: [NSView] = [NSTextField(labelWithString: "Knob \(letter(index))")]
            if draft.columns[index] == nil {
                let warning = NSTextField(labelWithString: "Needs calibration")
                warning.textColor = .systemRed
                leading.append(warning)
            }
            return row(leading, popup)
        }
        if rows.isEmpty {
            let empty = NSTextField(labelWithString: "No knobs. Press + to add one.")
            empty.textColor = .secondaryLabelColor
            let row = NSStackView()
            row.edgeInsets = NSEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
            row.addView(empty, in: .center)
            rows = [row]
        }
        setRows(knobRows, rows)
        knobEdit.setEnabled(draft.columns.count < 26, forSegment: 0)  // letters end at Z
        knobEdit.setEnabled(!draft.columns.isEmpty, forSegment: 1)
    }

    @objc func pickDraftProfile(_ sender: NSPopUpButton) {
        draft.active = sender.indexOfSelectedItem
        showSettings()
    }

    func confirm(_ message: String, _ info: String, then action: @escaping () -> Void) {
        guard let window = settingsWindow else { return }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.addButton(withTitle: "Remove").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { action() } }
    }

    @objc func editProfiles(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 {
            draft.profiles.append(Profile(name: "Profile \(draft.profiles.count + 1)"))
            draft.active = draft.profiles.count - 1
            showSettings()
            settingsWindow?.makeFirstResponder(profileName)
        } else if draft.profiles.count > 1 {
            let name = draft.profile.name.trimmingCharacters(in: .whitespaces)
            confirm("Remove \(name.isEmpty ? "this profile" : "“\(name)”")?",
                    "Its knob choices and shortcut go with it.") { [self] in
                draft.profiles.remove(at: draft.active)
                draft.active = min(draft.active, draft.profiles.count - 1)
                showSettings()
            }
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        draft.profile.name = profileName.stringValue
        profilePicker.selectedItem?.title = profileName.stringValue
    }

    @objc func pick(_ sender: NSPopUpButton) {
        var jobs = draft.profile.targets
        jobs += Array(repeating: nil, count: max(0, sender.tag + 1 - jobs.count))
        jobs[sender.tag] = sender.selectedItem?.representedObject as? Target
        draft.profile.targets = jobs
    }

    @objc func editKnobs(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 {
            if draft.columns.count < 26 { draft.columns.append(nil) }
            showSettings()
        } else if !draft.columns.isEmpty {
            confirm("Remove knob \(letter(draft.columns.count - 1))?",
                    "What it does in every profile goes with it.") { [self] in
                draft.columns.removeLast()
                // Else a knob added back would take up the removed knob's jobs.
                for index in draft.profiles.indices {
                    draft.profiles[index].targets = Array(draft.profiles[index].targets.prefix(draft.columns.count))
                }
                showSettings()
            }
        }
    }

    @objc func toggleOption() {
        draft.invert = invertKnobs.state == .on
        draft.showName = showName.state == .on
        draft.hideIcon = hideIcon.state == .on
        draft.icon = IconStyle.allCases[iconPicker.indexOfSelectedItem]
        showName.isEnabled = !draft.hideIcon
        iconPicker.isEnabled = !draft.hideIcon
        iconLabel.textColor = draft.hideIcon ? .disabledControlTextColor : .labelColor
    }

    // The shortcuts are off while recording, so pressing one records it instead of switching.
    @objc func recordShortcut() {
        guard recorder == nil else { return stopRecording() }
        registerHotKeys([])
        shortcutButton.title = "Press Shortcut"
        recorder = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.record(event)
            return nil
        }
    }

    // Needing ⌘ or ⌃ keeps a shortcut from swallowing typing in every app.
    func record(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        let shortcut = Shortcut(keyCode: event.keyCode, modifiers: flags.rawValue,
                                key: event.characters(byApplyingModifiers: []) ?? "")
        if Int(event.keyCode) == kVK_Delete && flags.isEmpty {
            draft.profile.shortcut = nil
        } else if Int(event.keyCode) != kVK_Escape {
            let taken = draft.profiles.indices.contains { $0 != draft.active && draft.profiles[$0].shortcut == shortcut }
            guard !shortcut.key.isEmpty, !flags.isDisjoint(with: [.command, .control]), !taken,
                  let probe = registerHotKey(shortcut, id: 0) else { return NSSound.beep() }
            UnregisterEventHotKey(probe)
            draft.profile.shortcut = shortcut
        }
        stopRecording()
    }

    func stopRecording() {
        if let recorder {
            NSEvent.removeMonitor(recorder)
            registerHotKeys(shared.config().setup.profiles)
        }
        recorder = nil
        shortcutButton.title = draft.profile.shortcut?.label ?? "Record Shortcut"
        removeShortcutButton.isHidden = draft.profile.shortcut == nil
    }

    @objc func removeShortcut() {
        draft.profile.shortcut = nil
        stopRecording()
    }

    @objc func saveSettings() {
        let calibrateNow = calibrateOnSave.state == .on
        prefs.set(calibrateNow, forKey: "calibrateOnSave")
        for index in draft.profiles.indices where draft.profiles[index].name.trimmingCharacters(in: .whitespaces).isEmpty {
            draft.profiles[index].name = "Profile \(index + 1)"
        }
        shared.setSetup(draft)
        registerHotKeys(draft.profiles)
        refresh()
        reloadDraft()
        if calibrateNow && shared.snapshot().connected { calibrate() }
    }
}
