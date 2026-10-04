#if canImport(AppKit)
import AppKit

// Absolute path because launchd does not put homebrew on PATH. The PATH lookup is only a
// courtesy for odd install locations.
func findM1ddc() -> String? {
    for path in ["/opt/homebrew/bin/m1ddc", "/usr/local/bin/m1ddc"]
    where FileManager.default.isExecutableFile(atPath: path) {
        return path
    }
    let which = Process()
    which.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    which.arguments = ["which", "m1ddc"]
    let pipe = Pipe()
    which.standardOutput = pipe
    which.standardError = FileHandle.nullDevice
    guard (try? which.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    which.waitUntilExit()
    let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return path.isEmpty ? nil : path
}

// Only ever changed on ddcQueue once running, where writeDDC reads it, so an install shows up without a restart.
var m1ddcPath = findM1ddc()

// Asks the hardware, not the running slice, so it is true under Rosetta too.
let isAppleSilicon: Bool = {
    var arm: Int32 = 0
    var size = MemoryLayout<Int32>.size
    return sysctlbyname("hw.optional.arm64", &arm, &size, nil, 0) == 0 && arm == 1
}()

// The uuid is what m1ddc addresses a monitor by; the id is what the HUD needs to pick a screen.
struct Display {
    let id: CGDirectDisplayID
    let uuid: String
    let x: CGFloat
    let builtin: Bool
}

// Split out from activeDisplays() so the ordering rule is testable without hardware. The
// built-in is dropped rather than sorted: it sits at a negative x on this machine, so
// leaving it in would silently make it "screen 1".
func orderExternals(_ displays: [Display]) -> [Display] {
    displays.filter { !$0.builtin }.sorted { $0.x < $1.x }
}

// Re-read on every use rather than cached with a reconfiguration callback: this is a handful
// of microseconds, and it means unplugging or rearranging monitors just works with no callback
// machinery.
func activeDisplays() -> [Display] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return [] }
    return ids[0..<Int(count)].compactMap { id -> Display? in
        guard let cf = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
              let uuid = CFUUIDCreateString(nil, cf) as String? else { return nil }
        return Display(id: id, uuid: uuid, x: CGDisplayBounds(id).origin.x,
                       builtin: CGDisplayIsBuiltin(id) != 0)
    }
}

func externalDisplays() -> [Display] { orderExternals(activeDisplays()) }

func builtinDisplayID() -> CGDirectDisplayID? { activeDisplays().first { $0.builtin }?.id }

// The display the pointer is on, or the main one, the display with the menu bar, if it is on none.
func pointerDisplayID() -> CGDirectDisplayID {
    var display: CGDirectDisplayID = 0
    var count: UInt32 = 0
    guard let pointer = CGEvent(source: nil)?.location,
          CGGetDisplaysWithPoint(pointer, 1, &display, &count) == .success, count > 0 else { return CGMainDisplayID() }
    return display
}

// Serial so two DDC writes never overlap. A write blocks for ~77ms, so it must never run on the
// serial thread: lines would back up behind it and stall the volume knob too.
let ddcQueue = DispatchQueue(label: "theej.ddc")

// Write only, never read back: these Dells answer every `get` with 0.
func writeDDC(_ uuid: String, _ feature: String, _ value: Int) -> Bool {
    guard let m1ddc = m1ddcPath else { return false }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: m1ddc)
    task.arguments = ["display", uuid, "set", feature, String(value)]
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    guard (try? task.run()) != nil else { return false }
    task.waitUntilExit()
    return task.terminationStatus == 0
}
#endif
