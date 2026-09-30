import AppKit
import Carbon.HIToolbox

extension NSToolbarItem.Identifier {
    static let general = Self("general")
    static let app = Self("app")
    static let about = Self("about")
}

// Settings' tabs in toolbar order, with their labels and SF Symbols.
let settingsTabs: [(id: NSToolbarItem.Identifier, label: String, symbol: String)] = [
    (.general, "General", "slider.vertical.3"), (.app, "App settings", "gearshape"), (.about, "About", "info.circle"),
]

let formWidth: CGFloat = 420  // every group, heading and footnote

// Flipped, so a page taller than the window starts at its top rather than its bottom.
final class TopClipView: NSClipView {
    override var isFlipped: Bool { true }
}

extension MenuBar: NSToolbarDelegate {
    // A second click keeps unsaved edits in an open window.
    @objc func openSettings() {
        if settingsWindow?.isVisible != true { draft = shared.config().setup }
        showSettings()
        settingsWindow?.makeFirstResponder(nil)  // else the name field opens with its text selected
    }

    // Three tabs of System Settings groups. Built once; after that only the rows and values change.
    func showSettings() {
        if settingsWindow != nil {
            reloadDraft()
            fitSettings()
        } else {
            setUpEdit(profileEdit, "Add a profile", "Remove this profile", #selector(editProfiles))
            setUpEdit(knobEdit, "Add a knob", "Remove the last knob", #selector(editKnobs))
            profilePicker.target = self
            profilePicker.action = #selector(pickDraftProfile)
            // Whatever the name, + and - stay in the window.
            profilePicker.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true
            profileName.delegate = self
            profileName.widthAnchor.constraint(equalToConstant: 180).isActive = true
            profileName.bezelStyle = .roundedBezel
            let profileGroup = group(profileRows)
            setRows(profileRows, [row([NSTextField(labelWithString: "Name")], profileName), shortcutRow("Shortcut")])
            let knobGroup = group(knobRows)
            let stepRows = NSStackView()
            let stepGroup = group(stepRows)
            setRows(stepRows, [shortcutRow("Next profile"), shortcutRow("Previous profile")])
            let profileShortcutGroup = group(profileShortcutRows)

            for control: NSControl in [invertKnobs, showName, hideIcon, iconPicker, showProfiles, speedPicker] {
                control.target = self
                control.action = #selector(toggleOption)
            }
            for toggle in [invertKnobs, showName, hideIcon, showProfiles] { toggle.controlSize = .mini }
            iconPicker.isBordered = false
            for style in IconStyle.allCases {
                iconPicker.addItem(withTitle: style.title)
                iconPicker.lastItem?.image = makeIcon(style, parked: false, side: 16)
            }
            speedPicker.isBordered = false
            for speed in Speed.allCases { speedPicker.addItem(withTitle: speed.title) }
            let speedRows = NSStackView()
            let speedGroup = group(speedRows)
            setRows(speedRows, [row([label("Speed", note: "How soon a change lands after a turn.")], speedPicker)])
            let optionRows = NSStackView()
            let optionGroup = group(optionRows)
            setRows(optionRows, [row([label("Invert knobs", note: "For pots wired the other way round.")], invertKnobs)])
            let menuBarRows = NSStackView()
            let menuBarGroup = group(menuBarRows)
            setRows(menuBarRows, [row([label("Hide menu bar icon", note: "Open \(appName) again to get back here.")], hideIcon),
                                  row([showNameLabel], showName),
                                  row([iconLabel], iconPicker),
                                  row([profileListLabel], showProfiles)])
            let caption = footnote("Choose what each knob does in this profile.")
            caption.addView(NSButton(title: "Calibrate", target: self, action: #selector(calibrate)), in: .trailing)
            let general = page([header("Profile", leading: [profilePicker], trailing: [profileEdit]), profileGroup,
                                header("Knobs", trailing: [knobEdit]), knobGroup, caption, optionGroup, saveFooter()])
            general.setCustomSpacing(24, after: profileGroup)
            general.setCustomSpacing(16, after: caption)
            general.setCustomSpacing(24, after: optionGroup)
            let app = page([header("Shortcuts"), stepGroup, profileShortcutGroup, header("Menu bar"), menuBarGroup,
                            header("Sensitivity"), speedGroup, saveFooter()])
            for view in [profileShortcutGroup, menuBarGroup, speedGroup] { app.setCustomSpacing(24, after: view) }
            tabs = [.general: general, .app: app, .about: aboutPage()]
            reloadDraft()
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
                                                   queue: .main) { [weak self] _ in self?.stopRecording() }
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                   queue: .main) { _ in NSApp.setActivationPolicy(.accessory) }
            settingsWindow = window
            showTab(.general)
            window.center()  // again, now that the toolbar has made it taller
        }
        // A regular app while Settings is open, so Cmd+Tab can switch back to it.
        NSApp.setActivationPolicy(.regular)
        present(settingsWindow!)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { settingsTabs.map(\.id) }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { settingsTabs.map(\.id) }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { settingsTabs.map(\.id) }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let tab = settingsTabs.first(where: { $0.id == id }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = tab.label
        item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.label)
        item.target = self
        item.action = #selector(pickTab)
        return item
    }

    @objc func pickTab(_ sender: NSToolbarItem) { showTab(sender.itemIdentifier) }

    func showTab(_ id: NSToolbarItem.Identifier) {
        guard let window = settingsWindow, let page = tabs[id] else { return }
        reloadDraft()  // a profile renamed in General has a row in App settings too
        window.toolbar?.selectedItemIdentifier = id
        window.title = settingsTabs.first { $0.id == id }?.label ?? ""
        (window.contentView as? NSScrollView)?.documentView = page
        fitSettings(animate: window.isVisible)
    }

    // The window takes the page's own height, or the screen's where that is less and the page scrolls.
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
    func page(_ views: [NSView]) -> NSStackView {
        let page = NSStackView(views: views)
        page.orientation = .vertical
        page.alignment = .leading
        page.spacing = 8
        page.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        page.setHuggingPriority(.defaultHigh, for: .horizontal)  // else fittingSize drops the right inset
        for view in views where !(view is NSBox) { view.widthAnchor.constraint(equalToConstant: formWidth).isActive = true }
        return page
    }

    func saveFooter() -> NSStackView {
        let save = NSButton(title: "Save", target: self, action: #selector(saveSettings))
        save.keyEquivalent = "\r"
        let footer = NSStackView()
        footer.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        footer.addView(save, in: .trailing)
        return footer
    }

    func aboutPage() -> NSStackView {
        let icon = NSImageView(image: makeAppIcon(side: 96, scale: 2))
        icon.widthAnchor.constraint(equalToConstant: 96).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 96).isActive = true
        let name = NSTextField(labelWithString: appName)
        name.font = .boldSystemFont(ofSize: 16)
        let version = NSTextField(labelWithString: "Version \(appVersion)")
        version.textColor = .secondaryLabelColor
        let check = NSButton(title: "Check for updates…", target: self, action: #selector(checkNow))
        let website = link("Website", "https://theej.zolfer.com/")
        let page = NSStackView(views: [icon, name, version, check, website, credit("Made by", "zolfer.com", "https://zolfer.com/"),
                                       credit("Inspired by", "deej", "https://github.com/omriharel/deej")])
        page.orientation = .vertical
        page.alignment = .centerX
        page.spacing = 4
        page.setCustomSpacing(12, after: icon)
        page.setCustomSpacing(16, after: version)
        page.setCustomSpacing(16, after: check)
        page.edgeInsets = NSEdgeInsets(top: 24, left: 20, bottom: 28, right: 20)
        page.widthAnchor.constraint(equalToConstant: formWidth + 40).isActive = true  // as wide as the other tabs
        return page
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

    func footnote(_ text: String) -> NSStackView {
        let note = NSStackView(views: [small(text)])
        note.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        return note
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
            box.widthAnchor.constraint(equalToConstant: formWidth),
        ])
        return box
    }

    // Makes the next of shortcutPaths its field and ✕, so rows have to be made in that order. The ✕
    // keeps its place while hidden, so the field doesn't move when a shortcut comes or goes.
    func shortcutRow(_ title: String) -> NSStackView {
        let button = NSButton(title: "", target: self, action: #selector(recordShortcut))
        button.tag = shortcutButtons.count
        button.toolTip = "Use ⌘ or ⌃ with a key. Delete clears it, Escape cancels."
        // With the ✕ after it, as wide as the name field: 156 + 8 + 16 = 180.
        button.widthAnchor.constraint(equalToConstant: 156).isActive = true
        let remove = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remove shortcut")!,
                              target: self, action: #selector(removeShortcut))
        remove.tag = button.tag
        remove.toolTip = "Remove shortcut"
        remove.isBordered = false
        remove.widthAnchor.constraint(equalToConstant: 16).isActive = true
        shortcutButtons.append(button)
        removeShortcutButtons.append(remove)
        let label = NSTextField(labelWithString: title)
        label.lineBreakMode = .byTruncatingTail  // a profile's name can be longer than the row has room for
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = row([label], button, remove)
        row.detachesHiddenViews = false
        return row
    }

    func row(_ leading: [NSView], _ trailing: NSView...) -> NSStackView {
        let row = NSStackView()
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 38).isActive = true  // one height whatever the control
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
        // Before stopRecording, which titles every field.
        shortcutButtons.removeSubrange(3...)
        removeShortcutButtons.removeSubrange(3...)
        setRows(profileShortcutRows, draft.profiles.enumerated().map { index, profile in
            let name = profile.name.trimmingCharacters(in: .whitespaces)
            return shortcutRow(name.isEmpty ? "Profile \(index + 1)" : name)
        })
        stopRecording()
        profilePicker.removeAllItems()
        for profile in draft.profiles {
            // Not addItem(withTitle:), which drops a second profile with the same name.
            profilePicker.menu?.addItem(withTitle: clipped(profile.name, to: 30), action: nil, keyEquivalent: "")
        }
        profilePicker.selectItem(at: draft.active)
        profileName.stringValue = draft.profile.name
        profileEdit.setEnabled(draft.profiles.count > 1, forSegment: 1)
        invertKnobs.state = draft.invert ? .on : .off
        showName.state = draft.showName ? .on : .off
        showProfiles.state = draft.showProfiles ? .on : .off
        hideIcon.state = draft.hideIcon ? .on : .off
        iconPicker.selectItem(at: IconStyle.allCases.firstIndex(of: draft.icon) ?? 0)
        speedPicker.selectItem(at: Speed.allCases.firstIndex(of: draft.speed) ?? 0)
        dimMenuBarOptions()

        let assigned = draft.profile.targets.compactMap { target -> Int? in
            switch target {
            case .brightness(let ordinal)?, .contrast(let ordinal)?: return ordinal + 1
            default: return nil
            }
        }.max() ?? 0
        // Includes an assigned monitor that is unplugged right now, so Save cannot drop it.
        let monitors: [Target] = (0..<max(2, externalDisplays().count, assigned))
            .flatMap { [.brightness($0), .contrast($0)] }
        // The open apps, and any app a profile already uses, so Save cannot drop one that isn't open.
        var apps: [Target] = []
        if #available(macOS 14.2, *) {
            let open = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
                .compactMap(\.bundleIdentifier)
            apps = draft.apps.union(open).subtracting([Bundle.main.bundleIdentifier ?? ""]).map(Target.app)
                .sorted { title($0).localizedStandardCompare(title($1)) == .orderedAscending }
        }
        let choices = ([Target.master, .microphone, .builtinBrightness, .builtinContrast, .nightShift,
                        .builtinKeyboard, .externalKeyboard] + monitors).sorted { rank($0) < rank($1) } + apps

        var rows = draft.columns.indices.map { index -> NSStackView in
            let popup = NSPopUpButton()
            popup.isBordered = false
            popup.addItem(withTitle: title(nil))
            popup.menu?.addItem(.separator())
            for (i, choice) in choices.enumerated() {
                if i == 0 || rank(choice) / 100 != rank(choices[i - 1]) / 100 {
                    popup.menu?.addItem(.sectionHeader(title: section(choice)))
                }
                // Not addItem(withTitle:), which drops the Monitor 1 under Brightness for the one under Contrast.
                let item = popup.menu?.addItem(withTitle: shortTitle(choice), action: nil, keyEquivalent: "")
                item?.representedObject = choice
                if case .app(let id) = choice, let icon = appIcon(id)?.copy() as? NSImage {
                    icon.size = NSSize(width: 16, height: 16)
                    item?.image = icon
                }
                if choice == draft.profile.target(index) { popup.select(item) }
            }
            showJob(popup)
            popup.tag = index
            popup.target = self
            popup.action = #selector(pick)
            popup.setAccessibilityLabel("Knob \(letter(index))")
            let note = draft.columns[index] == nil ? "Needs calibration" : nil
            return row([label("Knob \(letter(index))", note: note, noteColor: .systemRed)], popup)
        }
        if rows.isEmpty {
            let empty = NSTextField(labelWithString: "No knobs. Calibrate finds them, or press + to add one.")
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
        profilePicker.selectedItem?.title = clipped(profileName.stringValue, to: 30)
    }

    @objc func pick(_ sender: NSPopUpButton) {
        var jobs = draft.profile.targets
        jobs += Array(repeating: nil, count: max(0, sender.tag + 1 - jobs.count))
        jobs[sender.tag] = sender.selectedItem?.representedObject as? Target
        draft.profile.targets = jobs
        showJob(sender)
    }

    // The closed popup shows the job's full title: the list's short one leans on its section header.
    func showJob(_ popup: NSPopUpButton) {
        let cell = popup.cell as? NSPopUpButtonCell
        cell?.usesItemFromMenu = false
        cell?.menuItem = NSMenuItem(title: title(popup.selectedItem?.representedObject as? Target),
                                    action: nil, keyEquivalent: "")
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
        draft.showProfiles = showProfiles.state == .on
        draft.hideIcon = hideIcon.state == .on
        draft.icon = IconStyle.allCases[iconPicker.indexOfSelectedItem]
        draft.speed = Speed.allCases[speedPicker.indexOfSelectedItem]
        dimMenuBarOptions()
    }

    // With the icon hidden there is nothing in the menu bar to name, draw or open.
    func dimMenuBarOptions() {
        for control: NSControl in [showName, iconPicker, showProfiles] { control.isEnabled = !draft.hideIcon }
        for label in [showNameLabel, iconLabel, profileListLabel] {
            label.textColor = draft.hideIcon ? .disabledControlTextColor : .labelColor
        }
    }

    // The shortcuts are off while recording, so pressing one records it instead of switching. A click on
    // the field being recorded stops, and on another field records that one instead.
    @objc func recordShortcut(_ sender: NSButton) {
        let again = recorder != nil && recording == sender.tag
        stopRecording()
        guard !again else { return }
        registerHotKeys(nil)
        recording = sender.tag
        sender.title = "Press Shortcut"
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
        let path = shortcutPaths[recording]
        if Int(event.keyCode) == kVK_Delete && flags.isEmpty {
            draft[keyPath: path] = nil
        } else if Int(event.keyCode) != kVK_Escape {
            // Not another field's. By path, not index: the profile shown in General has a second field
            // in App settings, and would otherwise clash with itself.
            let taken = shortcutPaths.contains { $0 != path && draft[keyPath: $0] == shortcut }
            guard !shortcut.key.isEmpty, !flags.isDisjoint(with: [.command, .control]), !taken,
                  let probe = registerHotKey(shortcut, id: 0) else { return NSSound.beep() }
            UnregisterEventHotKey(probe)
            draft[keyPath: path] = shortcut
        }
        stopRecording()
    }

    func stopRecording() {
        if let recorder {
            NSEvent.removeMonitor(recorder)
            registerHotKeys(shared.config().setup)
        }
        recorder = nil
        for (path, (button, remove)) in zip(shortcutPaths, zip(shortcutButtons, removeShortcutButtons)) {
            button.title = draft[keyPath: path]?.label ?? "Record Shortcut"
            remove.isHidden = draft[keyPath: path] == nil
        }
    }

    @objc func removeShortcut(_ sender: NSButton) {
        let path = shortcutPaths[sender.tag]
        draft[keyPath: path] = nil
        stopRecording()
    }

    // An app's volume is set by capturing its audio, which macOS has to allow. It asks the first time,
    // and the answer only reaches a TheeJ started after it.
    func askForAudioCapture() {
        guard !audioCaptureAllowed() else { return }
        requestAudioCapture { [self] granted in
            let text = "To set an app's volume, \(appName) plays that app's sound back at the knob's level, which macOS "
                + "counts as recording it. Allow \(appName) under Screen & System Audio Recording in Privacy & Security, "
                + "then quit \(appName) and open it again."
            guard !granted, alert("\(appName) can't set app volumes yet", text, "Open System Settings", "Later") else { return }
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
        }
    }

    @objc func saveSettings() {
        for index in draft.profiles.indices where draft.profiles[index].name.trimmingCharacters(in: .whitespaces).isEmpty {
            draft.profiles[index].name = "Profile \(index + 1)"
        }
        shared.setSetup(draft)
        registerHotKeys(draft)
        refresh()
        reloadDraft()
        keepAppVolumes(for: draft.apps)
        if !draft.apps.isEmpty { askForAudioCapture() }
        if draft.columns.contains(nil) { startCalibration(onlyNew: true) }  // a knob added with + has no input yet
    }
}
