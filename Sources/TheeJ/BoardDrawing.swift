#if canImport(AppKit)
import AppKit

// A board as Settings draws it, in millimetres scaled to the view's width: the SMC-Mixer as its panel sits,
// from weej's device.js, and any other board as a row of knobs, one of faders and one of buttons. A click or
// the arrow keys pick a control, and its knobs and faders follow the board as it moves.
final class BoardDrawing: NSView {
    private enum Shape {
        case knob(center: NSPoint)
        case fader(x: CGFloat, top: CGFloat, length: CGFloat)
        case button(NSRect, glyph: String?, symbol: String?)
    }

    private struct Part {
        let control: Int
        let shape: Shape
        let hit: NSRect
        let labelY: CGFloat?  // where its label's middle sits, for the ones that have one
    }

    let board: Board
    private let parts: [Part]
    private let origin: NSPoint  // the drawing's top left, in millimetres
    private let size: NSSize  // in millimetres
    var values: [Int] = [] {  // each control's 0...1023, -1 while unknown
        didSet { needsDisplay = true }
    }
    var picked: Int? {
        didSet { needsDisplay = true }
    }
    var label: (Int) -> (text: String, more: Int, empty: Bool)? = { _ in nil }
    var assigned: (Int) -> Bool = { _ in false }
    var onPick: (Int) -> Void = { _ in }
    private var lit: [Int: Date] = [:]

    // controlColor is a see-through white in dark mode, and the track would show through a fader's cap.
    private static let cap = NSColor(name: nil) { look in
        look.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 0.42, alpha: 1) : .white
    }

    init(board: Board) {
        self.board = board
        (parts, origin, size) = board.type == .smc ? BoardDrawing.mixer() : BoardDrawing.rows(board)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalTo: widthAnchor, multiplier: size.height / size.width).isActive = true
        focusRingType = .exterior
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // Eight strips of a knob, an LED, a fader and the M, S, R and Square buttons, 18 mm apart, then the
    // bottom row. Knob 1's centre is 0,0.
    private static func mixer() -> ([Part], NSPoint, NSSize) {
        var parts: [Part] = []
        for strip in 0..<8 {
            let x = CGFloat(strip) * 18
            parts.append(Part(control: 8 + strip, shape: .knob(center: NSPoint(x: x, y: 0)),
                              hit: NSRect(x: x - 5.5, y: -5.5, width: 11, height: 16), labelY: 8.7))
            parts.append(Part(control: strip, shape: .fader(x: x, top: 15, length: 31.1),
                              hit: NSRect(x: x - 4.2, y: 12.4, width: 8.4, height: 41), labelY: 50.9))
            for (first, glyph, y) in [(16, "M", 20.1), (8, "S", 27.7), (0, "R", 35.4), (24, nil, 42.6)] {
                let rect = NSRect(x: x + 8.8 - 2.3, y: y - 2.3, width: 4.6, height: 4.6)
                parts.append(Part(control: noteButton(first + strip), shape: .button(rect, glyph: glyph, symbol: nil), hit: rect, labelY: nil))
            }
        }
        let symbols = ["play.fill", "pause.fill", "circle.fill", "backward.end.fill", "forward.end.fill", "chevron.left.2",
                       "chevron.right.2", "arrowtriangle.up.fill", "arrowtriangle.down.fill", "arrowtriangle.left.fill",
                       "arrowtriangle.right.fill"]
        for (index, note) in smcBottomNotes.enumerated() {
            let rect = NSRect(x: 5.04 + CGFloat(index) * 12.574 - 3.7, y: 57 - 2.1, width: 7.4, height: 4.2)
            parts.append(Part(control: noteButton(note), shape: .button(rect, glyph: nil, symbol: symbols[index]), hit: rect, labelY: nil))
        }
        return (parts, NSPoint(x: -8.8, y: -7.7), NSSize(width: 150, height: 69.8))
    }

    // Rows of 16 mm cells, each row as tall as its tallest control; at least as big as the SMC-Mixer, so a
    // small board isn't drawn huge.
    private static func rows(_ board: Board) -> ([Part], NSPoint, NSSize) {
        let rows = ControlKind.allCases.map { kind in board.controls.indices.filter { board.controls[$0].kind == kind } }
            .filter { !$0.isEmpty }
        let tall: [ControlKind: CGFloat] = [.knob: 16, .fader: 41, .button: 14]
        let heights = rows.map { row in row.map { tall[board.controls[$0].kind]! }.max()! }
        let content = heights.reduce(0, +) + 4 * CGFloat(max(rows.count - 1, 0))
        let width = max(150, CGFloat(rows.map(\.count).max() ?? 0) * 16 + 8)
        let height = max(69.8, content + 8)
        var y = (height - content) / 2
        var parts: [Part] = []
        for (row, controls) in rows.enumerated() {
            let left = (width - CGFloat(controls.count) * 16) / 2 + 8
            for (index, control) in controls.enumerated() {
                let x = left + CGFloat(index) * 16
                let cell = NSRect(x: x - 8, y: y, width: 16, height: tall[board.controls[control].kind]!)
                switch board.controls[control].kind {
                case .knob:
                    parts.append(Part(control: control, shape: .knob(center: NSPoint(x: x, y: y + 5.28)), hit: cell, labelY: y + 13.7))
                case .fader:
                    parts.append(Part(control: control, shape: .fader(x: x, top: y + 2.6, length: 30), hit: cell, labelY: y + 38.8))
                case .button:
                    let rect = NSRect(x: x - 3.5, y: y + 0.6, width: 7, height: 7)
                    parts.append(Part(control: control, shape: .button(rect, glyph: nil, symbol: nil), hit: cell, labelY: y + 11.7))
                }
            }
            y += heights[row] + 4
        }
        return (parts, .zero, NSSize(width: width, height: height))
    }

    private var scale: CGFloat { bounds.width / size.width }

    private func point(_ p: NSPoint) -> NSPoint {
        NSPoint(x: (p.x - origin.x) * scale, y: (p.y - origin.y) * scale)
    }

    private func rect(_ r: NSRect) -> NSRect {
        NSRect(origin: point(r.origin), size: NSSize(width: r.width * scale, height: r.height * scale))
    }

    private func value(_ control: Int) -> Int { control < values.count ? values[control] : -1 }

    // Lit for a second after it moves or is pressed.
    func light(_ control: Int) {
        lit[control] = Date().addingTimeInterval(1)
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) { [weak self] in self?.needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        if board.type == .smc {
            NSColor.tertiaryLabelColor.setFill()
            for strip in 0..<8 {
                let led = rect(NSRect(x: CGFloat(strip) * 18 - 2.16, y: 10, width: 4.32, height: 1.2))
                NSBezierPath(roundedRect: led, xRadius: led.height / 2, yRadius: led.height / 2).fill()
            }
        }
        let now = Date()
        for part in parts {
            let outline = draw(part)
            if (lit[part.control] ?? .distantPast) > now {
                NSColor.controlAccentColor.withAlphaComponent(0.3).setFill()
                outline.fill()
            }
            if part.control == picked {
                NSColor.controlAccentColor.setStroke()
                outline.lineWidth = max(1.5, 0.45 * scale)
                outline.stroke()
            } else if board.type != .smc, board.controls[part.control].input == nil {
                // Not found yet, so it waits for calibration.
                NSColor.controlAccentColor.setStroke()
                let waiting = NSBezierPath(roundedRect: rect(part.hit.insetBy(dx: 0.5, dy: 0.5)), xRadius: 4, yRadius: 4)
                waiting.setLineDash([3, 3], count: 2, phase: 0)
                waiting.stroke()
            }
            if let labelY = part.labelY, let text = label(part.control) { draw(text, at: part.hit.midX, labelY) }
        }
    }

    // Draws the part, and gives back its outline for the pick and the light.
    private func draw(_ part: Part) -> NSBezierPath {
        let face = NSColor.controlColor
        let edge = NSColor.secondaryLabelColor
        let line = max(1, 0.25 * scale)
        switch part.shape {
        case .knob(let center):
            let value = value(part.control)
            let radius = 4.68 * scale
            let c = point(center)
            let circle = NSBezierPath(ovalIn: NSRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
            face.setFill()
            circle.fill()
            edge.setStroke()
            circle.lineWidth = line
            circle.stroke()
            // Degrees clockwise from 12 o'clock, -135 at 0% to 135 at 100%.
            let angle = (-135 + 270 * CGFloat(max(value, 0)) / 1023) * .pi / 180
            let pointer = NSBezierPath()
            pointer.move(to: NSPoint(x: c.x + 1.7 * scale * sin(angle), y: c.y - 1.7 * scale * cos(angle)))
            pointer.line(to: NSPoint(x: c.x + 3.9 * scale * sin(angle), y: c.y - 3.9 * scale * cos(angle)))
            (value < 0 ? NSColor.tertiaryLabelColor : NSColor.labelColor).setStroke()
            pointer.lineWidth = max(1.5, 0.5 * scale)
            pointer.lineCapStyle = .round
            pointer.stroke()
            return NSBezierPath(ovalIn: NSRect(x: c.x - radius - 2, y: c.y - radius - 2, width: radius * 2 + 4, height: radius * 2 + 4))
        case .fader(let x, let top, let length):
            let well = NSBezierPath(roundedRect: rect(NSRect(x: x - 4.2, y: top - 2.6, width: 8.4, height: length + 5.2)),
                                    xRadius: 1.4 * scale, yRadius: 1.4 * scale)
            NSColor.quaternaryLabelColor.setFill()
            well.fill()
            let track = rect(NSRect(x: x - 0.675, y: top, width: 1.35, height: length))
            NSColor.tertiaryLabelColor.setFill()
            NSBezierPath(roundedRect: track, xRadius: track.width / 2, yRadius: track.width / 2).fill()
            // Mid-track and faint until the fader says where it is.
            let value = value(part.control)
            let y = top + (1 - (value < 0 ? 0.5 : CGFloat(value) / 1023)) * length
            let cap = rect(NSRect(x: x - 3.55, y: y - 1.9, width: 7.1, height: 3.8))
            let alpha: CGFloat = value < 0 ? 0.4 : 1
            let body = NSBezierPath(roundedRect: cap, xRadius: 0.7 * scale, yRadius: 0.7 * scale)
            BoardDrawing.cap.withAlphaComponent(alpha).setFill()
            body.fill()
            edge.withAlphaComponent(alpha).setStroke()
            body.lineWidth = line
            body.stroke()
            let mark = NSBezierPath()
            mark.move(to: NSPoint(x: cap.minX + 0.8 * scale, y: cap.midY))
            mark.line(to: NSPoint(x: cap.maxX - 0.8 * scale, y: cap.midY))
            mark.lineWidth = line
            mark.stroke()
            return well
        case .button(let box, let glyph, let symbol):
            let r = rect(box)
            let radius = (board.type == .smc ? 0.8 : 1) * scale
            let body = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
            face.setFill()
            body.fill()
            edge.setStroke()
            body.lineWidth = line
            body.stroke()
            if let glyph {
                let font = NSFont.systemFont(ofSize: 2.4 * scale, weight: .semibold)
                let text = NSAttributedString(string: glyph, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
                let size = text.size()
                text.draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2))
            } else if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor])) {
                let height = 2.2 * scale
                let width = height * image.size.width / max(image.size.height, 1)
                image.draw(in: NSRect(x: r.midX - width / 2, y: r.midY - height / 2, width: width, height: height),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else if board.type == .smc {
                let square = rect(NSRect(x: box.midX - 0.9, y: box.midY - 0.9, width: 1.8, height: 1.8))
                let glyphBox = NSBezierPath(roundedRect: square, xRadius: 0.35 * scale, yRadius: 0.35 * scale)
                NSColor.secondaryLabelColor.setStroke()
                glyphBox.lineWidth = line
                glyphBox.stroke()
            }
            // A dot by the corner of a button that does something.
            if assigned(part.control) {
                let dot = 0.55 * scale
                let centre = NSPoint(x: r.maxX - 0.9 * scale, y: r.minY + 0.9 * scale)
                NSColor.controlAccentColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: centre.x - dot, y: centre.y - dot, width: dot * 2, height: dot * 2)).fill()
            }
            return NSBezierPath(roundedRect: r.insetBy(dx: -2, dy: -2), xRadius: radius + 2, yRadius: radius + 2)
        }
    }

    // A label fitted to its strip, less a gap: 17 mm, with "+N" kept whole.
    private func draw(_ label: (text: String, more: Int, empty: Bool), at x: CGFloat, _ y: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: label.empty ? NSColor.tertiaryLabelColor : NSColor.secondaryLabelColor,
        ]
        let more = label.more > 0 ? " +\(label.more)" : ""
        let room = 17 * scale - (more as NSString).size(withAttributes: attributes).width
        var text = label.text
        while text.count > 1, (text as NSString).size(withAttributes: attributes).width > room {
            text = String(text.dropLast(text.hasSuffix("…") ? 2 : 1)).trimmingCharacters(in: .whitespaces) + "…"
        }
        let line = NSAttributedString(string: text + more, attributes: attributes)
        let size = line.size()
        let centre = point(NSPoint(x: x, y: y))
        line.draw(at: NSPoint(x: centre.x - size.width / 2, y: centre.y - size.height / 2))
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let mm = NSPoint(x: p.x / scale + origin.x, y: p.y / scale + origin.y)
        guard let part = parts.first(where: { $0.hit.contains(mm) }) else { return }
        window?.makeFirstResponder(self)
        onPick(part.control)
    }

    // The arrow keys go from control to control in the order they are drawn.
    override func keyDown(with event: NSEvent) {
        guard let index = parts.firstIndex(where: { $0.control == picked }) else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 123, 126: onPick(parts[max(index - 1, 0)].control)  // left, up
        case 124, 125: onPick(parts[min(index + 1, parts.count - 1)].control)  // right, down
        default: super.keyDown(with: event)
        }
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    // Each control is a button VoiceOver can name and press.
    override func accessibilityChildren() -> [Any]? {
        parts.map { part in
            let element = ControlElement(drawing: self, control: part.control)
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel(board.controlName(part.control))
            element.setAccessibilityValue(label(part.control).map { $0.more > 0 ? "\($0.text) +\($0.more)" : $0.text } ?? "")
            element.setAccessibilityFrameInParentSpace(rect(part.hit))
            element.setAccessibilityParent(self)
            return element
        }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { board.name }
}

private final class ControlElement: NSAccessibilityElement {
    weak var drawing: BoardDrawing?
    let control: Int

    init(drawing: BoardDrawing, control: Int) {
        (self.drawing, self.control) = (drawing, control)
        super.init()
    }

    override func accessibilityPerformPress() -> Bool {
        drawing?.onPick(control)
        return true
    }
}
#endif
