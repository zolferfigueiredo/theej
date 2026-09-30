import AppKit

extension MenuBar {
    // Every knob, from A: the menu's Calibrate and the button in Settings.
    @objc func calibrate() {
        startCalibration(onlyNew: false)
    }

    // The window says what to do, and Cancel leaves everything as it was, so it opens straight away.
    // onlyNew, for Save and the automatic start, asks only for the knobs that have no input yet.
    func startCalibration(onlyNew: Bool) {
        if let window = calibrationWindow, calibrator != nil {
            present(window)
            return
        }
        calibrator = Calibrator(saved: shared.config().setup.columns, onlyNew: onlyNew)
        if calibrationWindow == nil {
            stepTitle.font = .boldSystemFont(ofSize: 16)
            stepBody.preferredMaxLayoutWidth = 360
            stepBody.widthAnchor.constraint(equalToConstant: 360).isActive = true
            stepProgress.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            cancelButton.keyEquivalent = "\u{1b}"
            skipButton.target = self
            skipButton.action = #selector(skipKnob)
            let buttons = NSStackView()
            buttons.addView(cancelButton, in: .trailing)
            buttons.addView(skipButton, in: .trailing)
            let content = NSStackView(views: [stepTitle, stepBody, stepProgress, buttons])
            content.orientation = .vertical
            content.alignment = .leading
            content.spacing = 12
            content.setCustomSpacing(20, after: stepProgress)
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
        shared.setCalibrating(true)
    }

    // handle() sends every line here while calibrating.
    func feed(_ values: [Int], at now: Double) {
        guard var run = calibrator else { return }
        let before = (run.knob, run.phase, run.full)
        run.feed(values, at: now)
        calibrator = run
        if (run.knob, run.phase, run.full) != before {
            NSSound(named: "Tink")?.play()  // the user is watching the knob, not the screen
            showStep()
        } else {
            showProgress(run)
        }
    }

    // Once per launch, as the board connects: on a fresh install, or after + in Settings, a knob has no input yet.
    func calibrateIfNeeded() {
        let columns = shared.config().setup.columns
        guard !calibrationOffered, columns.isEmpty || columns.contains(nil) else { return }
        calibrationOffered = true
        startCalibration(onlyNew: true)
    }

    func showStep() {
        guard let run = calibrator, let window = calibrationWindow else { return }
        let name = letter(run.knob)
        let turns = Int(Calibrator.turnSeconds)
        // The first knob also says why, and what the turning after it is for.
        var move = tr(run.knob == run.first ? "cal.move_first" : "cal.move", ["letter": name, "n": turns])
        var more: [String] = []
        if run.canSkip {
            more.append(tr("cal.skip_keeps"))
        } else if run.knob < run.saved.count {
            more.append(tr("cal.finish_later"))
        } else if run.knob > 0 {
            more.append(tr("cal.no_knob", ["letter": name]))
        }
        if run.knob == run.first { more.append(tr("cal.hold")) }
        // Chinese and Japanese put no space between sentences.
        for sentence in more { move += ([.zh, .ja].contains(Language.current) ? "" : " ") + sentence }
        let steps = [move, tr("cal.turn", ["n": turns])]
        window.title = tr("calibration_title")  // set here, not once, so a language change reaches an open window
        cancelButton.title = tr("cancel")
        stepTitle.stringValue = run.full ? tr("cal.all_found") : tr("knob", ["letter": name])
        stepBody.stringValue = run.full ? tr("cal.all_found_text", ["n": run.found.count]) : steps[run.phase]
        showProgress(run)
        skipButton.title = run.canSkip ? tr("skip") : tr("finish")
        fit(window)
    }

    func showProgress(_ run: Calibrator) {
        stepProgress.stringValue = progress(run)
        stepProgress.textColor = run.paused || run.wrongKnob != nil ? .systemOrange : .secondaryLabelColor
    }

    func progress(_ run: Calibrator) -> String {
        if run.full { return plural("knobs_found", run.found.count) }
        if let wrong = run.wrongKnob { return tr("cal.wrong", ["wrong": letter(wrong), "letter": letter(run.knob)]) }
        if run.phase == 0 {
            return shared.snapshot().connected ? tr("cal.waiting_knob", ["letter": letter(run.knob)]) : tr("cal.waiting_board")
        }
        let left = plural("seconds_left", Int(run.left.rounded(.up)))
        return run.paused ? tr("cal.paused", ["left": left, "letter": letter(run.knob)]) : left
    }

    @objc func skipKnob() {
        if calibrator?.canSkip == true {
            calibrator?.skip()
            showStep()
        } else {
            finish()
        }
    }

    // Saves before closing: windowWillClose throws the run away. With nothing to save, as when Finish
    // comes straight away, it ends like Cancel.
    func finish() {
        guard let run = calibrator else { return }
        var setup = shared.config().setup
        guard run.result != setup.columns else { calibrationWindow?.close(); return }
        setup.columns = run.result
        shared.setSetup(setup)
        calibrationWindow?.close()
        // Started from an open Settings, which may hold unsaved edits: only the inputs change there.
        if settingsWindow?.isVisible == true { draft.columns = setup.columns } else { draft = setup }
        showSettings()
        showTab(.general)  // where each knob's job is chosen
    }

    // Every way out of a run ends here, Cancel and the close button included, so the knobs never
    // stay silenced. Only the calibration window has this delegate.
    func windowWillClose(_ notification: Notification) {
        calibrator = nil
        shared.setCalibrating(false)
    }
}
