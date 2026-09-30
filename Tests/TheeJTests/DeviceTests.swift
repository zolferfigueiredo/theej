import AppKit
import Carbon.HIToolbox
import Testing
@testable import TheeJ

// The built-in sits at a negative x. It must be dropped, not sorted to the front.
@Test func externalsLeftToRightWithoutTheBuiltIn() {
    let fake = { (uuid: String, x: CGFloat, builtin: Bool) in Display(id: 0, uuid: uuid, x: x, builtin: builtin) }
    #expect(orderExternals([fake("R", 2560, false), fake("BUILTIN", -1470, true), fake("L", 0, false)]).map(\.uuid) == ["L", "R"])
    #expect(orderExternals([fake("BUILTIN", 0, true)]).isEmpty)
}

@Test func shortcutModifiersForCarbon() {
    #expect(carbonModifiers([.command, .shift]) == UInt32(cmdKey | shiftKey))
}

@Test func viaBacklightReports() {
    #expect(viaReports(1).map { Array($0.prefix(4)) } == [[7, 0x80, 255, 0], [7, 3, 1, 255]])
    #expect(viaReports(0.1).allSatisfy { $0.count == 32 })
}

@Test func serialLines() {
    #expect(parse("7|1023|0\r") == [7, 1023, 0])
    #expect(parse("7||0") == nil && parse("1024") == nil)
}
