import AppKit

// The menu bar icon's looks, picked in Settings. The raw values are saved, so renaming one resets it.
enum IconStyle: String, CaseIterable {
    case mixer, dial, app

    var title: String { tr("icon.\(rawValue)") }
}

// Parked means disconnected: the mixer's knobs drop to the bottom and the dial's pointer to its minimum.
// The app icon never changes. Numbers are in a 24-unit design space, y down, tuned to stay crisp at 18pt
// on a Retina menu bar. Mixer and dial are templates so macOS colours them for light and dark menu
// bars, which is also why their gaps cannot use colour: a template image is an alpha mask.
func makeIcon(_ style: IconStyle, parked: Bool, side: CGFloat = 18) -> NSImage {
    if style == .app { return makeAppIcon(side: side, scale: 2) }
    let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { box in
        let s = box.width / 24
        func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: box.minX + x * s, y: box.minY + (24 - y) * s)
        }
        func rect(_ cx: CGFloat, _ cy: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
            let c = pt(cx, cy)
            return NSRect(x: c.x - w * s / 2, y: c.y - h * s / 2, width: w * s, height: h * s)
        }
        func stroke(_ path: NSBezierPath, _ width: CGFloat) {
            path.lineWidth = width * s
            path.lineCapStyle = .round
            path.stroke()
        }
        func line(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat, _ width: CGFloat) {
            let path = NSBezierPath()
            path.move(to: pt(x0, y0))
            path.line(to: pt(x1, y1))
            stroke(path, width)
        }
        let ink = NSColor.black
        ink.setStroke()
        ink.setFill()
        let context = NSGraphicsContext.current

        if style == .mixer {
            // The app icon's three faders cut out of its tile, the knobs at its heights.
            NSBezierPath(roundedRect: rect(12, 12, 20, 20), xRadius: 4.67 * s, yRadius: 4.67 * s).fill()
            context?.compositingOperation = .clear
            for (x, y) in zip([6.67, 12, 17.33], parked ? [16.67, 16.67, 16.67] : [8, 14, 10.67]) {
                line(x, 6, x, 18, 1.33)
                NSBezierPath(roundedRect: rect(x, y, 4, 2.67), xRadius: 0.8 * s, yRadius: 0.8 * s).fill()
            }
        } else {
            // A knob in a 270 degree track, lit from 7:30 up to the pointer: 1:30 when connected, two
            // thirds up. Degrees run clockwise from 12 o'clock; AppKit's arcs run the other way.
            let cx: CGFloat = 12, cy: CGFloat = 13.17
            let pointer: CGFloat = parked ? -135 : 45
            func arc(_ to: CGFloat, _ color: NSColor) {
                let path = NSBezierPath()
                path.appendArc(withCenter: pt(cx, cy), radius: 9.67 * s, startAngle: 225, endAngle: 90 - to,
                               clockwise: true)
                color.setStroke()
                stroke(path, 1.33)
            }
            arc(135, NSColor.black.withAlphaComponent(0.35))
            if !parked { arc(pointer, ink) }
            NSBezierPath(ovalIn: rect(cx, cy, 12.66, 12.66)).fill()
            context?.compositingOperation = .clear
            let angle = pointer * .pi / 180
            line(cx + sin(angle) * 1.67, cy - cos(angle) * 1.67, cx + sin(angle) * 4.33, cy - cos(angle) * 4.33, 1.6)
        }
        context?.compositingOperation = .sourceOver
        return true
    }
    image.isTemplate = true
    return image
}

// The mixer from theej.zolfer.com, three faders and an orange LED on a cream plate, laid out on
// Apple's icon grid: an 824 square with 185 corners on a 1024 canvas. build.sh bakes it into
// AppIcon.icns. Drawn in those 1024 units with y down, into a bitmap made here: its base space stays
// y-up, so a shadow of negative height falls down the screen whatever draws the image.
func makeAppIcon(side: CGFloat, scale: CGFloat = 1) -> NSImage {
    let px = Int(side * scale), s = side * scale / 1024
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: s, y: -s)

    func rgb(_ hex: Int, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat(hex >> 16) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }
    func gray(_ white: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: white, green: white, blue: white, alpha: alpha)
    }
    func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
        CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
    func paint(_ path: CGPath, _ topToBottom: [CGColor]) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let box = path.boundingBox
        ctx.drawLinearGradient(CGGradient(colorsSpace: srgb, colors: topToBottom as CFArray, locations: nil)!,
                               start: CGPoint(x: 0, y: box.minY), end: CGPoint(x: 0, y: box.maxY), options: [])
        ctx.restoreGState()
    }
    // The shadow of everything outside the path, cast inside it: up shades the bottom edge of a
    // raised plate, down shades the top of a cut.
    func inset(_ path: CGPath, dy: CGFloat, blur: CGFloat, _ color: CGColor) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.setShadow(offset: CGSize(width: 0, height: dy * s), blur: blur * s, color: color)
        ctx.addRect(CGRect(x: -100, y: -100, width: 1224, height: 1224))
        ctx.addPath(path)
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
    }

    // Cream enamel lit from above, each pixel up to 2% lighter or darker for grain. The fixed seed
    // keeps every build the same. Row 0 lands at the bottom of the y down space.
    let top: [CGFloat] = [0xf1, 0xec, 0xe2], bottom: [CGFloat] = [0xdd, 0xd5, 0xc6]
    var plate = [UInt8](repeating: 255, count: px * px * 4)
    var seed: UInt64 = 1
    for i in stride(from: 0, to: plate.count, by: 4) {
        let t = min(1, max(0, (924 - CGFloat(i / 4 / px) / s) / 824))
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        let grain = CGFloat(Int(seed >> 56) - 128) * 0.04
        for c in 0..<3 {
            plate[i + c] = UInt8(max(0, min(255, top[c] + (bottom[c] - top[c]) * t * t * (3 - 2 * t) + grain)))
        }
    }
    let tile = rounded(CGRect(x: 100, y: 100, width: 824, height: 824), 185)
    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    ctx.draw(CGImage(width: px, height: px, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: px * 4, space: srgb,
                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                     provider: CGDataProvider(data: Data(plate) as CFData)!, decode: nil,
                     shouldInterpolate: false, intent: .defaultIntent)!,
             in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    ctx.restoreGState()
    inset(tile, dy: 16, blur: 34, gray(0, 0.2))
    inset(tile, dy: -5, blur: 6, gray(1, 0.9))

    for (x, knob) in [(322, 360), (512, 610), (702, 470)] as [(CGFloat, CGFloat)] {
        let slot = rounded(CGRect(x: x - 17, y: 250, width: 34, height: 540), 17)
        ctx.addPath(slot)
        ctx.setFillColor(rgb(0x161514))
        ctx.fillPath()
        inset(slot, dy: -10, blur: 14, gray(0))
        ctx.saveGState()
        ctx.translateBy(x: 0, y: 2)
        ctx.addPath(slot)
        ctx.setStrokeColor(gray(1, 0.35))
        ctx.setLineWidth(3)
        ctx.strokePath()
        ctx.restoreGState()
        ctx.setStrokeColor(rgb(0xa39d92))
        ctx.setLineWidth(8)
        ctx.setLineCap(.round)
        for y in stride(from: CGFloat(270), through: 770, by: 100) {
            ctx.move(to: CGPoint(x: x + 58, y: y))
            ctx.addLine(to: CGPoint(x: x + 84, y: y))
        }
        ctx.strokePath()

        let cap = CGRect(x: x - 66, y: knob - 38, width: 132, height: 76)
        let body = rounded(cap, 15.2)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12 * s), blur: 24 * s, color: gray(0, 0.55))
        ctx.addPath(body)
        ctx.fillPath()
        ctx.restoreGState()
        paint(body, [gray(0.24), gray(0.1), gray(0.05)])
        paint(rounded(cap.insetBy(dx: 5.3, dy: 6.1), 10.6), [gray(0.2), gray(0.08)])
        ctx.saveGState()
        ctx.addPath(body)
        ctx.clip()
        ctx.move(to: CGPoint(x: cap.minX + 15, y: cap.minY + 2))
        ctx.addLine(to: CGPoint(x: cap.maxX - 15, y: cap.minY + 2))
        ctx.setStrokeColor(gray(1, 0.18))
        ctx.setLineWidth(4)
        ctx.strokePath()
        ctx.restoreGState()
        ctx.addPath(rounded(CGRect(x: x - 39.6, y: knob - 4.6, width: 79.2, height: 9.2), 4.6))
        ctx.setFillColor(rgb(0xebe5d9))
        ctx.fillPath()
    }

    let led = CGPoint(x: 212, y: 212)
    ctx.drawRadialGradient(CGGradient(colorsSpace: srgb, colors: [rgb(0xff5a1f, 0.55), rgb(0xff5a1f, 0)] as CFArray,
                                      locations: nil)!,
                           startCenter: led, startRadius: 13, endCenter: led, endRadius: 70, options: [])
    ctx.addEllipse(in: CGRect(x: led.x - 22, y: led.y - 22, width: 44, height: 44))
    ctx.clip()
    ctx.drawRadialGradient(CGGradient(colorsSpace: srgb, colors: [rgb(0xffd999), rgb(0xff5a1f), rgb(0xb33c0c)] as CFArray,
                                      locations: [0, 0.45, 1])!,
                           startCenter: CGPoint(x: led.x - 6.6, y: led.y - 7.7), startRadius: 0, endCenter: led,
                           endRadius: 22, options: .drawsAfterEndLocation)
    return NSImage(cgImage: ctx.makeImage()!, size: NSSize(width: side, height: side))
}
