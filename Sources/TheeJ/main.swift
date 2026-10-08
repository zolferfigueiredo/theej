#if canImport(AppKit)
import AppKit
import UserNotifications

// build.sh runs this to render the app icon into an .iconset, then iconutil packs it.
if let flag = args.firstIndex(of: "--iconset"), flag + 1 < args.count {
    let dir = URL(fileURLWithPath: args[flag + 1])
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // Nothing under 64 px: macOS 26 puts small drawn sizes on a grey plate, and scales the 64 px one down cleanly.
    for points in [32, 128, 256, 512] {
        for scale in [1, 2] where points * scale >= 64 {
            let px = points * scale
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            makeAppIcon(side: CGFloat(px)).draw(in: NSRect(x: 0, y: 0, width: px, height: px))
            NSGraphicsContext.restoreGraphicsState()
            let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
            try rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name))
        }
    }
    exit(0)
}

setvbuf(stdout, nil, _IOLBF, 0)

let app = NSApplication.shared
// Opening the app again through Launch Services reaches applicationShouldHandleReopen instead. A copy
// started directly, as ./run.sh does, hands over here, so two never fight over a board.
// deliverImmediately, since TheeJ is never the active app and would otherwise not get it.
let settingsRequest = Notification.Name("com.zolfer.theej.settings")
if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
    .contains(where: { $0.processIdentifier != getpid() }) {
    DistributedNotificationCenter.default().postNotificationName(settingsRequest, object: nil, userInfo: nil,
                                                                 deliverImmediately: true)
    print("\(appName) is already running, so its Settings opened instead. Quit it first to run this copy.")
    exit(0)
}

app.setActivationPolicy(.accessory)  // menu bar only; a regular app only while Settings is open
// Before anything else opens and before the setup loads, which names a new install's first profile.
// Its buttons hold it weakly, so it is kept alive until Continue.
if prefs.string(forKey: "language") == nil { withExtendedLifetime(LanguagePrompt()) { $0.run() } }

let saved = shared.config().setup
for board in saved.boards {
    print("\(appName): \(board.name), \(board.type.rawValue)\(board.enabled ? "" : ", off"), profile \(board.profile.name)")
    for (index, control) in board.controls.enumerated() where control.kind != .button {
        let input = control.input.map { "input \($0)" } ?? "not calibrated"
        print("\(appName):   \(board.controlName(index)), \(input): \(title(board.profile.jobs(of: index)))")
    }
}
if m1ddcPath == nil {
    fputs("m1ddc not found, external brightness and contrast are disabled. brew install m1ddc\n", stderr)
}
if displayServices == nil {
    fputs("DisplayServices unavailable, built-in brightness is disabled.\n", stderr)
}
if setDisplayContrast == nil {
    fputs("CGSSetDisplayContrast unavailable, built-in contrast is disabled.\n", stderr)
}
if blueLight == nil {
    fputs("CoreBrightness unavailable, Night Shift is disabled.\n", stderr)
}
if keyboardLight == nil {
    fputs("CoreBrightness unavailable, the built-in keyboard backlight is disabled.\n", stderr)
}
if zoomServices == nil {
    fputs("CGSSetZoomParameters unavailable, screen zoom is disabled.\n", stderr)
}

menuBar = MenuBar()
app.delegate = menuBar
UNUserNotificationCenter.current().delegate = menuBar
DispatchQueue.main.async { menuBar?.showUpdateComplete() }  // once the app is running
if prefs.bool(forKey: "testNotifications") { Task { _ = await showUpdateNotification(nextPatch(appVersion)) } }
DistributedNotificationCenter.default().addObserver(forName: settingsRequest, object: nil, queue: .main) { _ in
    menuBar?.openSettings()
}
installHotKeyHandler()
midi = MIDI()
startBoards()
if saved.boards.isEmpty { DispatchQueue.main.async { menuBar?.openSettings() } }  // where a first board is added
app.run()
#endif
