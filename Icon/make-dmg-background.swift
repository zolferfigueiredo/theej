// DMG window background: a warm grey from the plate's cream and the faders' graphite, with the LED's orange glowing
// behind the app and a white arrow from the app (left) to the Applications link (right). Positions must match dmg/layout.sh. release.sh runs this:
// swift Icon/make-dmg-background.swift <output folder>
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let width: CGFloat = 640, height: CGFloat = 400
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: srgb, components: [r / 255, g / 255, b / 255, a])!
}

func gradient(_ stops: [(CGColor, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: srgb, colors: stops.map(\.0) as CFArray, locations: stops.map(\.1))!
}

// A soft glow: `color` at (x, y), fading out by `stop` of an ellipse rx by ry, all as fractions of the window.
func radial(_ ctx: CGContext, _ color: CGColor, rx: CGFloat, ry: CGFloat, x: CGFloat, y: CGFloat, stop: CGFloat) {
    ctx.saveGState()
    ctx.translateBy(x: x * width, y: y * height)
    ctx.scaleBy(x: rx * width, y: ry * height)
    ctx.drawRadialGradient(gradient([(color, 0), (color.copy(alpha: 0)!, stop)]),
                           startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
    ctx.restoreGState()
}

func draw(scale: CGFloat) -> CGImage {
    let ctx = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8,
                        bytesPerRow: 0, space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Flip to y-down, like Finder's icon positions.
    ctx.translateBy(x: 0, y: height * scale)
    ctx.scaleBy(x: scale, y: -scale)

    ctx.drawLinearGradient(gradient([(rgb(112, 105, 94), 0), (rgb(74, 69, 61), 0.45), (rgb(32, 30, 26), 1)]),
                           start: CGPoint(x: 0, y: 0), end: CGPoint(x: width * 0.3, y: height), options: [.drawsAfterEndLocation])
    radial(ctx, rgb(0, 0, 0, 0.5), rx: 0.7, ry: 0.6, x: 0.96, y: 1, stop: 0.7)
    radial(ctx, rgb(255, 90, 31, 0.32), rx: 0.5, ry: 0.6, x: 0.25, y: 0.45, stop: 0.7)

    // Finder draws the icons' names in black even in Dark Mode, so each sits on a light box, as in Firefox's DMG.
    // Finder puts a 13 pt name from 268 to 280 pt, centred under its icon. Both boxes take the longer name's width.
    let font = CTFontCreateUIFontForLanguage(.system, 13, nil)!
    let widest = ["TheeJ.app", "Applications"].map { name in
        CTLineGetTypographicBounds(CTLineCreateWithAttributedString(
            NSAttributedString(string: name, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])), nil, nil, nil)
    }.max()!
    let boxWidth = max(120, widest + 28)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 4, color: rgb(0, 0, 0, 0.35))
    ctx.setFillColor(rgb(252, 246, 236, 0.92))
    for x: CGFloat in [160, 480] {
        ctx.addPath(CGPath(roundedRect: CGRect(x: x - boxWidth / 2, y: 262, width: boxWidth, height: 24),
                           cornerWidth: 7, cornerHeight: 7, transform: nil))
    }
    ctx.fillPath()
    ctx.restoreGState()

    // Curved arrow over the gap between the two 128 pt icons centred at (160, 190) and (480, 190).
    let from = CGPoint(x: 236, y: 176), control = CGPoint(x: 320, y: 92), to = CGPoint(x: 402, y: 172)
    let angle = atan2(to.y - control.y, to.x - control.x), head: CGFloat = 20, spread: CGFloat = 0.5
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 3), blur: 8, color: rgb(0, 0, 0, 0.5))
    ctx.setStrokeColor(rgb(255, 255, 255, 0.95))
    ctx.setLineWidth(6)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: from)
    ctx.addQuadCurve(to: to, control: control)
    ctx.move(to: CGPoint(x: to.x - head * cos(angle - spread), y: to.y - head * sin(angle - spread)))
    ctx.addLine(to: to)
    ctx.addLine(to: CGPoint(x: to.x - head * cos(angle + spread), y: to.y - head * sin(angle + spread)))
    ctx.strokePath()
    ctx.restoreGState()

    return ctx.makeImage()!
}

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for (scale, name) in [(1, "background.png"), (2, "background@2x.png")] as [(CGFloat, String)] {
    let dest = CGImageDestinationCreateWithURL(folder.appendingPathComponent(name) as CFURL,
                                               UTType.png.identifier as CFString, 1, nil)!
    let dpi = 72 * scale
    CGImageDestinationAddImage(dest, draw(scale: scale),
                               [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(name)") }
}
