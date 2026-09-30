import AppKit

extension MenuBar {
    // The window says what to do, and Cancel leaves everything as it was, so it opens straight away.
    @objc func calibrate() {
        if let window = calibrationWindow, calibrator != nil {
            present(window)
            return
        }
        calibrator = Calibrator(saved: shared.config().setup.columns)
        if calibrationWindow == nil {
            stepTitle.font = .boldSystemFont(ofSize: 16)
            stepBody.preferredMaxLayoutWidth = 360
            stepBody.widthAnchor.constraint(equalToConstant: 360).isActive = true
            stepProgress.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            let cancel = NSButton(title: "Cancel", target: nil, action: #selector(NSWindow.performClose(_:)))
            cancel.keyEquivalent = "\u{1b}"
            skipButton.target = self
            skipButton.action = #selector(skipKnob)
            let buttons = NSStackView()
            buttons.addView(cancel, in: .trailing)
            buttons.addView(skipButton, in: .trailing)
            let content = NSStackView(views: [stepTitle, stepBody, stepProgress, buttons])
            content.orientation = .vertical
            content.alignment = .leading
            content.spacing = 12
            content.setCustomSpacing(20, after: stepProgress)
            content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
            content.setHuggingPriority(.defaultHigh, for: .horizontal)
            buttons.widthAnchor.constraint(equalTo: stepBody.widthAnchor).isActive = true
            let window = makeWindow("\(appName) Calibration", content)
            window.delegate = self
            cancel.target = window
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
        calibrate()
    }

    func showStep() {
        guard let run = calibrator, let window = calibrationWindow else { return }
        let name = letter(run.knob)
        var move = "Move knob \(name) from one end to the other"
        if run.knob == 0 {
            move += ", so \(appName) can tell which knob is which. Each knob then takes a minute or two of turning, "
                + "which also cleans a jumpy one"
        }
        move += "."
        if run.canSkip {
            move += " It's already set up, so Skip keeps it as it is."
        } else if run.knob > 0 {
            move += " If you don't have a knob \(name), click Finish."
        }
        if run.knob == 0 { move += " Your knobs hold still until you finish." }
        let steps = [
            move,
            "Found it. Now turn it slowly, back and forth. The timer only runs while it turns.",
            "Now turn it fast.",
            "Slowly again.",
            "Sweep it from one end to the other, \(Calibrator.sweepsNeeded) times.",
        ]
        stepTitle.stringValue = run.full ? "All knobs found" : "Knob \(name)"
        stepBody.stringValue = run.full
            ? "Your board sends \(run.found.count) values, and each one has its knob now, so that's all of them. "
                + "Click Finish to choose what they do."
            : steps[run.phase]
        showProgress(run)
        skipButton.title = run.canSkip ? "Skip" : "Finish"
        fit(window)
    }

    func showProgress(_ run: Calibrator) {
        stepProgress.stringValue = progress(run)
        stepProgress.textColor = run.paused || run.wrongKnob != nil ? .systemOrange : .secondaryLabelColor
    }

    func progress(_ run: Calibrator) -> String {
        if run.full { return run.found.count == 1 ? "1 knob found" : "\(run.found.count) knobs found" }
        if let wrong = run.wrongKnob { return "That's knob \(letter(wrong)). Move knob \(letter(run.knob)) instead." }
        switch run.phase {
        case 0: return shared.snapshot().connected ? "Waiting for knob \(letter(run.knob)) to move" : "Waiting for the board to connect"
        case 4: return "Sweep \(run.sweeps) of \(Calibrator.sweepsNeeded)"
        default:
            let seconds = Int(run.left.rounded(.up))
            let left = seconds == 1 ? "1 second left" : "\(seconds) seconds left"
            return run.paused ? "Paused with \(left). Keep turning knob \(letter(run.knob))." : left
        }
    }

    @objc func skipKnob() {
        if calibrator?.canSkip == true {
            calibrator?.skip()
            showStep()
        } else {
            finish()
        }
    }

    // Saves before closing: windowWillClose throws the run away. The knobs found become the knobs, and
    // with none found it ends like Cancel. Jobs past the last knob stay, for when it is found again.
    func finish() {
        guard let run = calibrator else { return }
        guard !run.found.isEmpty else { calibrationWindow?.close(); return }
        var setup = shared.config().setup
        setup.columns = run.found
        shared.setSetup(setup)
        calibrationWindow?.close()
        // Started from an open Settings, which may hold unsaved edits: only the inputs change there.
        if settingsWindow?.isVisible == true { draft.columns = setup.columns } else { draft = setup }
        showSettings()
    }

    // Every way out of a run ends here, Cancel and the close button included, so the knobs never
    // stay silenced. Only the calibration window has this delegate.
    func windowWillClose(_ notification: Notification) {
        calibrator = nil
        shared.setCalibrating(false)
    }
}
