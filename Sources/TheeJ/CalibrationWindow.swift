import AppKit

extension MenuBar {
    // runModal only ever runs from here, a menu or button action. Inside a main queue block (feed)
    // it would stall every line queued behind it until the alert closed.
    @objc func calibrate() {
        if let window = calibrationWindow, calibrator != nil {
            present(window)
            return
        }
        let count = shared.config().setup.columns.count
        guard count > 0 else { return }
        let turns = Int(Calibrator.turnSeconds)
        let alert = NSAlert()
        alert.messageText = count == 1 ? "Calibrate knob A?" : "Calibrate knobs A to \(letter(count - 1))?"
        alert.informativeText = """
            This takes about \(count == 1 ? "a minute" : "\(count) minutes, one per knob"). For each \
            knob, you first move it from one end to the other so \(appName) can tell which one it is. \
            Then you turn it slowly, fast, and slowly again for \(turns) seconds each, and sweep it \
            \(Calibrator.sweepsNeeded) times. The timers only run while the knob turns.

            You can skip a knob, but please don't skip one that jumps around: turning it is what cleans it.

            Every knob holds still until you finish.
            """
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        calibrator = Calibrator(knobs: count)
        if calibrationWindow == nil {
            stepTitle.font = .boldSystemFont(ofSize: 16)
            stepBody.preferredMaxLayoutWidth = 360
            stepBody.widthAnchor.constraint(equalToConstant: 360).isActive = true
            stepProgress.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            stepProgress.textColor = .secondaryLabelColor
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
        let before = (run.knob, run.phase)
        run.feed(values, at: now)
        calibrator = run
        if run.done {
            finish()
        } else if (run.knob, run.phase) != before {
            NSSound(named: "Tink")?.play()  // the user is watching the knob, not the screen
            showStep()
        } else {
            stepProgress.stringValue = progress(run)
        }
    }

    func showStep() {
        guard let run = calibrator, let window = calibrationWindow else { return }
        let name = letter(run.knob)
        let found = run.found[run.knob] == nil ? "" : "Found it. "
        stepTitle.stringValue = "Knob \(name), \(run.knob + 1) of \(run.found.count)"
        stepBody.stringValue = [
            "Move knob \(name) from one end to the other.",
            "\(found)Now turn it slowly, back and forth.",
            "Now turn it fast.",
            "Slowly again.",
            "Sweep it from one end to the other, \(Calibrator.sweepsNeeded) times.",
        ][run.phase]
        stepProgress.stringValue = progress(run)
        skipButton.title = "Skip knob \(name)"
        fit(window)
    }

    func progress(_ run: Calibrator) -> String {
        switch run.phase {
        case 0: return "Waiting for knob \(letter(run.knob)) to move"
        case 4: return "Sweep \(run.sweeps) of \(Calibrator.sweepsNeeded)"
        default:
            let seconds = Int(run.left.rounded(.up))
            return seconds == 1 ? "1 second left" : "\(seconds) seconds left"
        }
    }

    @objc func skipKnob() {
        calibrator?.skip()
        if calibrator?.done == true { finish() } else { showStep() }
    }

    // Saves before closing: windowWillClose throws the run away.
    func finish() {
        guard let run = calibrator else { return }
        var setup = shared.config().setup
        setup.columns = calibrated(setup.columns, found: run.found)
        shared.setSetup(setup)
        calibrationWindow?.close()
        draft = setup
        showSettings()
    }

    // Every way out of a run ends here, Cancel and the close button included, so the knobs never
    // stay silenced. Only the calibration window has this delegate.
    func windowWillClose(_ notification: Notification) {
        calibrator = nil
        shared.setCalibrating(false)
    }
}
