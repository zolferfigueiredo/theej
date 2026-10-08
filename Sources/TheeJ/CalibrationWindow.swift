#if canImport(AppKit)
import AppKit

extension MenuBar {
    // The given controls of a board, every one when none are given. The window says what to do, and Cancel
    // leaves everything as it was, so it opens straight away. Another board's run stops first.
    func startWizard(_ id: String, controls: [Int]? = nil) {
        guard let board = shared.config().setup.board(id), board.type != .smc else { return }
        if wizard?.board == id, let window = calibrationWindow, window.isVisible { return present(window) }
        calibrationWindow?.close()
        wizard = (id, CalWizard(board, controls: controls ?? Array(board.controls.indices)))
        shared.setCalibrating(id)
        if calibrationWindow == nil {
            stepTitle.font = .boldSystemFont(ofSize: 16)
            for text in [stepBody, stepWarning, stepNote] {
                text.preferredMaxLayoutWidth = 380
                text.widthAnchor.constraint(equalToConstant: 380).isActive = true
            }
            stepCount.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            stepWarning.textColor = .systemOrange
            stepNote.textColor = .secondaryLabelColor
            cancelButton.keyEquivalent = "\u{1b}"
            for (button, action) in [(redoButton, #selector(wizardRedo)), (skipButton, #selector(wizardSkip)), (nextButton, #selector(wizardNext))] {
                button.target = self
                button.action = action
            }
            nextButton.keyEquivalent = "\r"
            let buttons = NSStackView()
            buttons.addView(redoButton, in: .leading)
            buttons.addView(skipButton, in: .leading)
            buttons.addView(cancelButton, in: .trailing)
            buttons.addView(nextButton, in: .trailing)
            let content = NSStackView(views: [stepTitle, stepBody, stepCount, stepWarning, stepNote, buttons])
            content.orientation = .vertical
            content.alignment = .leading
            content.spacing = 12
            content.setCustomSpacing(20, after: stepNote)
            content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
            content.setHuggingPriority(.defaultHigh, for: .horizontal)
            buttons.widthAnchor.constraint(equalTo: stepBody.widthAnchor).isActive = true
            let window = makeWindow("", content)
            window.delegate = self
            cancelButton.target = window
            calibrationWindow = window
        }
        showStep()
        present(calibrationWindow!)
    }

    // Once per launch per board, as it connects with a control not found yet: after Add, or a board from
    // before boards that was never calibrated.
    func calibrateIfNeeded(_ id: String) {
        guard let board = shared.config().setup.board(id), board.type != .smc, !board.calibrated,
              calibrationOffered.insert(id).inserted, wizard == nil else { return }
        startWizard(id, controls: board.controls.indices.filter { board.controls[$0].input == nil })
    }

    // The board's frames and presses while it is calibrated, from the engine. A control found plays a
    // sound: the user is watching the board, not the screen.
    func feedWizard(_ id: String, _ raw: [Int]) {
        guard var run = wizard?.run, wizard?.board == id else { return }
        let before = (run.position, run.stage, run.count, run.warning)
        run.feed(raw)
        update(run, before)
    }

    func pressWizard(_ id: String, _ key: Int) {
        guard var run = wizard?.run, wizard?.board == id else { return }
        let before = (run.position, run.stage, run.count, run.warning)
        run.press(key)
        update(run, before)
    }

    private func update(_ run: CalWizard, _ before: (Int, CalWizard.Stage, Int, CalWizard.Warning?)) {
        wizard?.run = run
        if run.position != before.0 || run.count != before.2 { NSSound(named: "Tink")?.play() }
        if run.position != before.0 || run.stage != before.1 || run.count != before.2 || run.warning != before.3 { showStep() }
    }

    func showStep() {
        guard let (id, run) = wizard, let window = calibrationWindow, let board = shared.config().setup.board(id) else { return }
        window.title = tr("wizard.title", ["name": board.name])  // set here, not once, so a language change reaches an open window
        let name = run.current.map(board.controlName) ?? ""
        let finding = run.stage == .find || run.stage == .press
        stepTitle.stringValue = finding ? tr("wizard.step", ["i": run.position + 1, "n": run.order.count]) + ": " + name : ""
        stepTitle.isHidden = !finding
        stepBody.stringValue = switch run.stage {
        case .zero: tr("wizard.zero")
        case .full: tr("wizard.full")
        case .find: tr("wizard.find", ["name": name])
        case .press: tr("wizard.press", ["name": name])
        case .done: tr("wizard.done")
        }
        stepCount.stringValue = tr("wizard.count", ["n": run.count, "of": 3])
        stepCount.isHidden = run.stage != .press
        stepWarning.stringValue = switch run.warning {
        case .wrong(let other)?: tr("wizard.wrong", ["other": board.controlName(other), "name": name])
        case .mismatch?: tr("wizard.mismatch", ["name": name])
        case .nothing?: tr("wizard.nothing")
        case .unswept?: tr("wizard.unswept")
        case nil: ""
        }
        stepWarning.isHidden = run.warning == nil
        stepNote.stringValue = tr("wizard.waiting", ["name": board.name])
        stepNote.isHidden = shared.status(id).connected
        cancelButton.title = tr("cancel")
        redoButton.title = tr("wizard.redo")
        redoButton.isHidden = run.stage == .zero || run.stage == .done
        skipButton.title = tr("skip")
        skipButton.isHidden = !finding
        nextButton.title = run.stage == .done ? tr("finish") : tr("add.next")
        nextButton.isHidden = !(run.stage == .zero || run.stage == .full || run.stage == .done)
        fit(window)
    }

    @objc func wizardNext() {
        guard let run = wizard?.run else { return }
        if run.done { return finishWizard() }
        wizard?.run.next()
        showStep()
    }

    @objc func wizardSkip() {
        wizard?.run.skip()
        showStep()
    }

    @objc func wizardRedo() {
        wizard?.run.redo()
        showStep()
    }

    // Saves before closing: windowWillClose throws the run away. Settings then opens on the board, where
    // each control's job is chosen.
    func finishWizard() {
        guard let (id, run) = wizard else { return }
        var setup = shared.config().setup
        if let index = setup.index(of: id) { setup.boards[index].controls = run.result }
        if let index = draft.index(of: id) { draft.boards[index].controls = run.result }
        shared.setSetup(setup)
        calibrationWindow?.close()
        let open = settingsWindow?.isVisible == true
        if !open { draft = setup }
        shownBoard = id
        showSettings()
        showTab(.boards)
    }

    // Every way out of a run ends here, Cancel and the close button included, so the board never stays
    // silenced. Only the calibration window has this delegate.
    func windowWillClose(_ notification: Notification) {
        wizard = nil
        shared.setCalibrating(nil)
    }
}
#endif
