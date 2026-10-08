import Foundation

// A button's actions, spelled as WeeJ saves them so a profile reads alike in both apps. The ones with a
// colon carry a setting after it: a control, an app's bundle identifier, a web address, keys or a profile.
let plainActions: Set<String> = [
    "media.playpause", "media.play", "media.pause", "media.stop", "media.previous", "media.next", "volume.up",
    "volume.down", "mute.all", "mute.mic", "nightlight", "screens.off", "pc.lock", "pc.sleep", "profile.next",
    "profile.previous", "settings", "lights.next", "lights.previous", "lights.on", "lights.off",
]

// The actions whose setting a button asks for under its tick.
let settingActions = ["open:", "close:", "url:", "keys:"]

private func setting(_ action: String, _ prefix: String) -> String? {
    guard action.hasPrefix(prefix), action.count > prefix.count else { return nil }
    return String(action.dropFirst(prefix.count))
}

// A plain non-negative number, so "mute:01" is no control.
private func index(_ text: String) -> Int? {
    Int(text).flatMap { $0 >= 0 && String($0) == text ? $0 : nil }
}

func mutedControl(_ action: String) -> Int? { setting(action, "mute:").flatMap(index) }

func profileTarget(_ action: String) -> Int? { setting(action, "profile:").flatMap(index) }

func appToOpen(_ action: String) -> String? { setting(action, "open:") }

func appToClose(_ action: String) -> String? { setting(action, "close:") }

func website(_ action: String) -> URL? {
    guard let address = setting(action, "url:"), ["http://", "https://"].contains(where: { address.lowercased().hasPrefix($0) }) else { return nil }
    return URL(string: address)
}

// "keys:<modifiers>:<keyCode>:<key>", WeeJ's order. The key goes last, since it may be a colon.
func keysAction(_ shortcut: Shortcut) -> String { "keys:\(shortcut.modifiers):\(shortcut.keyCode):\(shortcut.key)" }

func pressedKeys(_ action: String) -> Shortcut? {
    guard let rest = setting(action, "keys:") else { return nil }
    let fields = rest.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
    guard fields.count == 3, let modifiers = UInt(fields[0]), let keyCode = UInt16(fields[1]) else { return nil }
    return Shortcut(keyCode: keyCode, modifiers: modifiers, key: String(fields[2]))
}

func validAction(_ action: String) -> Bool {
    plainActions.contains(action) || mutedControl(action) != nil || profileTarget(action) != nil
        || appToOpen(action) != nil || appToClose(action) != nil || website(action) != nil || pressedKeys(action) != nil
}

// F13 to F20, keys no Mac keyboard has, so another app can take a button's press without a clash. Macs have
// no F21 to F24. The key is the character AppKit types for each.
let functionKeys: [(action: String, title: String)] = zip(13...20, [0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A]).map { n, keyCode in
    let key = String(Character(Unicode.Scalar(0xF710 + n - 13)!))
    return (keysAction(Shortcut(keyCode: UInt16(keyCode), modifiers: 0, key: key)), "F\(n)")
}

// The menu item an action is ticked under: itself, or the kind of one that takes a setting.
func actionKind(_ action: String) -> String {
    if functionKeys.contains(where: { $0.action == action }) { return action }
    return settingActions.first { action.hasPrefix($0) } ?? action
}

#if canImport(AppKit)
import AppKit

// Main thread. A profile action switches the board the button is on.
func perform(_ action: String, on id: String) {
    if let bundle = appToOpen(action) {
        // Brings it forward when it is open already.
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    } else if let bundle = appToClose(action) {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundle).forEach { $0.terminate() }
    } else if let url = website(action) {
        NSWorkspace.shared.open(url)
    } else if let keys = pressedKeys(action) {
        postKeys(keys)
    } else if let profile = profileTarget(action) {
        menuBar?.setProfiles([HotKeyTarget(board: id, profile: profile)])
    }
    switch action {
    // A Mac has one key for play and pause, and none for stop.
    case "media.playpause", "media.play", "media.pause": postMediaKey(16)
    case "media.next": postMediaKey(17)
    case "media.previous": postMediaKey(18)
    case "volume.up": stepVolume(1)
    case "volume.down": stepVolume(-1)
    case "mute.all":
        if let muted = toggleMute() { showOSD(osdVolumeImage, on: CGMainDisplayID(), muted ? 0 : volume() ?? 0) }
    case "mute.mic":
        if let muted = toggleMute(input: true) { showHUD(muted ? "mic.slash.fill" : hudMicrophone, on: CGMainDisplayID(), muted ? 0 : volume(input: true) ?? 0) }
    case "nightlight":
        if let on = toggleNightShift() { showHUD(hudNightShift, on: CGMainDisplayID(), on ? 1 : 0) }
    case "screens.off": runTool("/usr/bin/pmset", "displaysleepnow")
    case "pc.lock": lockScreen()
    case "pc.sleep": runTool("/usr/bin/pmset", "sleepnow")
    case "profile.next": menuBar?.setProfiles([HotKeyTarget(board: id, step: 1)])
    case "profile.previous": menuBar?.setProfiles([HotKeyTarget(board: id, step: -1)])
    case "settings": menuBar?.openSettings()
    case "lights.next": menuBar?.changeLights(id, nextLightPattern)
    case "lights.previous": menuBar?.changeLights(id, previousLightPattern)
    case "lights.on": menuBar?.changeLights(id) { _ in "on" }
    case "lights.off": menuBar?.changeLights(id) { _ in "" }
    default: break
    }
}

// The keys a key action and the media keys post are what macOS asks Accessibility for.
func postsKeys(_ action: String) -> Bool {
    action.hasPrefix("media.") || pressedKeys(action) != nil
}

func postKeys(_ shortcut: Shortcut) {
    let pairs: [(NSEvent.ModifierFlags, CGEventFlags)] = [(.command, .maskCommand), (.shift, .maskShift),
                                                          (.option, .maskAlternate), (.control, .maskControl)]
    let flags = pairs.reduce(CGEventFlags()) { shortcut.flags.contains($1.0) ? $0.union($1.1) : $0 }
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.keyCode, keyDown: down)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }
}

// key is NX_KEYTYPE_PLAY 16, NEXT 17 or PREVIOUS 18, sent as the keyboard's media keys are: a system
// defined event, subtype 8, down then up.
func postMediaKey(_ key: Int) {
    for down in [true, false] {
        NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00),
                           timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                           data1: key << 16 | (down ? 0xA : 0xB) << 8, data2: -1)?.cgEvent?.post(tap: .cghidEventTap)
    }
}

// The volume keys' sixteenths, unmuting as they do.
func stepVolume(_ by: Int) {
    let level = min(max(((volume() ?? 0) * 16).rounded() + Float32(by), 0), 16) / 16
    setMuted(false)
    setVolume(level)
    showOSD(osdVolumeImage, on: CGMainDisplayID(), level)
}

private func runTool(_ path: String, _ arguments: String...) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    try? process.run()
}

private let login = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY)

// The lock that Control Center's Lock Screen uses. Private, so it may be missing, and then nothing happens.
func lockScreen() {
    typealias Lock = @convention(c) () -> Int32
    guard let symbol = login.flatMap({ dlsym($0, "SACLockScreenImmediate") }) else { return }
    _ = unsafeBitCast(symbol, to: Lock.self)()
}

// An action's name in the menus and lists. A mute names its control, and a profile its name.
func actionTitle(_ action: String, on board: Board) -> String {
    if let key = functionKeys.first(where: { $0.action == action }) { return key.title }
    if let control = mutedControl(action) { return tr("action.mute", ["name": board.controlName(control)]) }
    if let profile = profileTarget(action) {
        return tr("action.go_profile", ["name": board.profiles.indices.contains(profile) ? board.profiles[profile].name : "\(profile + 1)"])
    }
    let keys = ["media.playpause": "action.play_pause", "media.play": "action.play", "media.pause": "action.pause",
                "media.previous": "action.previous_track", "media.next": "action.next_track", "volume.up": "action.volume_up",
                "volume.down": "action.volume_down", "mute.all": "action.mute_all", "open:": "action.open_app",
                "close:": "action.close_app", "url:": "action.open_url", "mute.mic": "action.mute_mic", "keys:": "action.keys",
                "nightlight": "action.night_light", "screens.off": "action.screens_off", "pc.lock": "action.lock",
                "pc.sleep": "action.sleep", "profile.previous": "previous_profile", "profile.next": "next_profile",
                "settings": "action.open_settings", "lights.next": "action.next_lights", "lights.previous": "action.previous_lights",
                "lights.on": "action.lights_on", "lights.off": "action.lights_off"]
    return keys[actionKind(action)].map { tr($0) } ?? action
}

func actionIcon(_ action: String) -> NSImage? {
    let symbols = ["media.playpause": "playpause.fill", "media.play": "play.fill", "media.pause": "pause.fill",
                   "media.previous": "backward.end.fill", "media.next": "forward.end.fill", "volume.up": "speaker.plus.fill",
                   "volume.down": "speaker.minus.fill", "mute.all": "speaker.slash.fill", "open:": "macwindow",
                   "close:": "xmark.square", "url:": "globe", "mute.mic": "mic.slash.fill", "keys:": "keyboard",
                   "nightlight": "moon.fill", "screens.off": "display", "pc.lock": "lock.fill", "pc.sleep": "powersleep",
                   "profile.previous": "arrow.left", "profile.next": "arrow.right", "settings": "gearshape",
                   "lights.next": "lightbulb", "lights.previous": "lightbulb", "lights.on": "lightbulb.fill",
                   "lights.off": "lightbulb.slash"]
    let kind = actionKind(action)
    let name = mutedControl(action) != nil ? "speaker.slash" : profileTarget(action) != nil ? "list.bullet" : symbols[kind]
    return name.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
}
#endif
