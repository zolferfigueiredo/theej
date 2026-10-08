#if canImport(AppKit)
import AppKit
import Carbon.HIToolbox

// Carbon hot keys are the global shortcuts that need no Accessibility or Input Monitoring permission.
// A key combination is registered once, with its place in hotKeyBindings as id, since one may switch
// several boards; every save registers them all again.
var hotKeys: [EventHotKeyRef] = []  // main thread only, where Carbon calls the handler
var hotKeyTargets: [[HotKeyTarget]] = []  // by id
let probeHotKey = UInt32.max  // a recorded shortcut, registered for a moment to see whether another app has it

func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
    [(NSEvent.ModifierFlags.command, cmdKey), (.shift, shiftKey), (.option, optionKey), (.control, controlKey)]
        .reduce(0) { flags.contains($1.0) ? $0 | UInt32($1.1) : $0 }
}

func registerHotKey(_ shortcut: Shortcut, id: UInt32) -> EventHotKeyRef? {
    var ref: EventHotKeyRef?
    let status = RegisterEventHotKey(UInt32(shortcut.keyCode), carbonModifiers(shortcut.flags),
                                     EventHotKeyID(signature: 0x5468654A, id: id),
                                     GetEventDispatcherTarget(), 0, &ref)
    return status == noErr ? ref : nil
}

// nil while a shortcut is being recorded, so pressing one records it instead of switching.
func registerHotKeys(_ setup: Setup?) {
    hotKeys.forEach { UnregisterEventHotKey($0) }
    let bindings = setup.map { hotKeyBindings($0.boards) } ?? []
    hotKeyTargets = bindings.map(\.targets)
    hotKeys = bindings.enumerated().compactMap { registerHotKey($1.shortcut, id: UInt32($0)) }
}

func installHotKeyHandler() {
    var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
        var id = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                          nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
        if hotKeyTargets.indices.contains(Int(id.id)) { menuBar?.setProfiles(hotKeyTargets[Int(id.id)]) }
        return noErr
    }, 1, &pressed, nil, nil)
}
#endif
