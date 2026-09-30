import AppKit
import Carbon.HIToolbox

// Carbon hot keys are the global shortcuts that need no Accessibility or Input Monitoring
// permission. Each id is its profile's index, so every save registers them all again.
var hotKeys: [EventHotKeyRef] = []  // main thread only, where Carbon calls the handler

func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
    [(NSEvent.ModifierFlags.command, cmdKey), (.shift, shiftKey), (.option, optionKey), (.control, controlKey)]
        .reduce(0) { flags.contains($1.0) ? $0 | UInt32($1.1) : $0 }
}

func registerHotKey(_ shortcut: Shortcut, id: Int) -> EventHotKeyRef? {
    var ref: EventHotKeyRef?
    let status = RegisterEventHotKey(UInt32(shortcut.keyCode), carbonModifiers(shortcut.flags),
                                     EventHotKeyID(signature: 0x5468654A, id: UInt32(id)),
                                     GetEventDispatcherTarget(), 0, &ref)
    return status == noErr ? ref : nil
}

func registerHotKeys(_ profiles: [Profile]) {
    hotKeys.forEach { UnregisterEventHotKey($0) }
    hotKeys = profiles.enumerated().compactMap { index, profile in
        profile.shortcut.flatMap { registerHotKey($0, id: index) }
    }
}

func installHotKeyHandler() {
    var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
        var id = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                          nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
        menuBar?.switchProfile(Int(id.id))
        return noErr
    }, 1, &pressed, nil, nil)
}
