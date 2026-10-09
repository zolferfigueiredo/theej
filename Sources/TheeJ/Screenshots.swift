#if canImport(AppKit)
import AppKit
import ScreenCaptureKit

// Settings' General tab and Boards tab, in Draw and List, and the calibration window finding knob B, with a made-up
// board of 5 knobs, 5 faders and 5 buttons, dark and light, written as the README's PNGs. Nothing is saved: the
// board stands in for the saved ones in memory only.
func takeScreenshots(into dir: URL) -> Never {
    // The argument domain is never written to disk. updateEvery 0 keeps MenuBar.init from checking for updates, and
    // WhenScrolling hides the scroll bars a connected mouse would show.
    UserDefaults.standard.setVolatileDomain(["language": "en", "updateEvery": 0, "AppleShowScrollBars": "WhenScrolling"],
                                            forName: UserDefaults.argumentDomain)
    var board = Board.make(id: nextBoardID(0), name: "Desk board", type: .diy, knobs: 5, faders: 5, buttons: 5,
                           profileName: tr("default_profile"))
    for index in board.controls.indices { board.controls[index].input = index }
    board.profiles[0].jobs = board.fitted([[.master], [.microphone], [.nightShift], [.zoom], [.builtinKeyboard],
                                           [.builtinBrightness], [.builtinContrast], [.master, .microphone], [.externalKeyboard], []])
    board.profiles[0].buttons = [10: ["media.playpause"], 11: ["media.next"], 12: ["mute.mic"], 13: ["profile.next"]]
    var setup = shared.config().setup
    setup.boards = [board]
    shared.setSetup(setup, save: false)
    shared.setStatus(board.id, BoardStatus(connected: true, port: "/dev/cu.usbmodem1101"))
    let bar = MenuBar()
    bar.draft.boards = [board]
    bar.liveValues[board.id] = [767, 409, 563, 205, 921, 818, 512, 665, 1023, 307] + Array(repeating: -1, count: 5)
    bar.picked[board.id] = 0
    Task { @MainActor in
        guard #available(macOS 14.4, *) else {
            fputs("--screenshots needs macOS 14.4 or later.\n", stderr)
            exit(1)
        }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            bar.showSettings()
            for (look, suffix) in [(NSAppearance.Name.aqua, "-light"), (.darkAqua, "")] {
                NSApp.appearance = NSAppearance(named: look)
                for (tab, list, name) in [(NSToolbarItem.Identifier.general, false, "settings-general"), (.boards, false, "boards-draw"),
                                          (.boards, true, "boards-list")] {
                    bar.draft.boards[0].list = list
                    bar.showTab(tab)
                    // NSApp.activate() is refused while another app is in use, and an inactive window draws grey. The
                    // deprecated call still takes focus; by selector, as its warning would fail CI.
                    NSApp.perform(NSSelectorFromString("activateIgnoringOtherApps:"), with: true)
                    try await Task.sleep(for: .seconds(1.5))
                    try await save(bar.settingsWindow!, as: "theej-\(name)\(suffix).png", in: dir)
                }
                // Read at 0% and at 100%, then knob A turned back to 0%: the window asks for knob B.
                if bar.wizard == nil {
                    let board = bar.draft.boards[0]
                    bar.startWizard(board.id)
                    let pots = board.controls.indices.filter { board.controls[$0].kind != .button }
                    let frame = { (pot: Int) in board.controls.indices.map { pots.contains($0) ? pot : 0 } }
                    bar.wizard?.run.feed(frame(0))
                    bar.wizard?.run.next()
                    bar.wizard?.run.feed(frame(1023))
                    bar.wizard?.run.next()
                    bar.wizard?.run.feed(frame(1023).enumerated().map { $0.offset == 0 ? 0 : $0.element })
                    bar.showStep()
                }
                bar.present(bar.calibrationWindow!)
                NSApp.perform(NSSelectorFromString("activateIgnoringOtherApps:"), with: true)
                try await Task.sleep(for: .seconds(1.5))
                try await save(bar.calibrationWindow!, as: "theej-calibration\(suffix).png", in: dir)
            }
            exit(0)
        } catch {
            fputs("Screenshots failed: \(error)\n", stderr)
            exit(1)
        }
    }
    NSApplication.shared.run()
    exit(0)
}

@available(macOS 14.4, *)
@MainActor
private func save(_ window: NSWindow, as name: String, in dir: URL) async throws {
    let file = dir.appendingPathComponent(name)
    try NSBitmapImageRep(cgImage: try await capture(window)).representation(using: .png, properties: [:])!.write(to: file)
    print(file.path)
}

// currentProcess needs no Screen Recording permission, since it only reaches this app's own windows.
@available(macOS 14.4, *)
@MainActor
private func capture(_ window: NSWindow) async throws -> CGImage {
    let content = try await SCShareableContent.currentProcess
    guard let shown = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
        throw CocoaError(.fileNoSuchFile)
    }
    let config = SCStreamConfiguration()
    config.width = Int(shown.frame.width * window.backingScaleFactor)
    config.height = Int(shown.frame.height * window.backingScaleFactor)
    config.ignoreShadowsSingleWindow = true
    config.showsCursor = false
    return try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: shown),
                                                      configuration: config)
}
#endif
