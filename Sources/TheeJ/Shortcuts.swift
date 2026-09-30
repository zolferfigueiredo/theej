#if canImport(AppKit)
import AppKit
import Carbon.HIToolbox

// Carbon hot keys are the global shortcuts that need no Accessibility or Input Monitoring
// permission. A profile's own shortcut has its index as id, so every save registers them all again,
// and Next and Previous profile have the two ids at the top.
var hotKeys: [EventHotKeyRef] = []  // main thread only, where Carbon calls the handler
let nextProfileKey = UInt32.max
let previousProfileKey = UInt32.max - 1

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
    let profiles = setup?.profiles.enumerated().map { ($1.shortcut, UInt32($0)) } ?? []
    let keys = profiles + [(setup?.next, nextProfileKey), (setup?.previous, previousProfileKey)]
    hotKeys = keys.compactMap { shortcut, id in shortcut.flatMap { registerHotKey($0, id: id) } }
}

func installHotKeyHandler() {
    var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
        var id = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                          nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
        switch id.id {
        case nextProfileKey: menuBar?.stepProfile(1)
        case previousProfileKey: menuBar?.stepProfile(-1)
        default: menuBar?.switchProfile(Int(id.id))
        }
        return noErr
    }, 1, &pressed, nil, nil)
}
#endif
