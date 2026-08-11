// Generates OmniStats' app icon (1024×1024 PNG) — a "thermal instrument": a dark
// squircle with the app's signature temperature gauge (green→red arc) and a
// thermometer glyph, plus a teal operating-point dot. Rendered headlessly with
// AppKit so it needs no design tools. Run via tools/gen-icon.sh.
import AppKit

let S: CGFloat = 1024

func hex(_ h: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((h >> 16) & 0xFF)/255, green: CGFloat((h >> 8) & 0xFF)/255,
            blue: CGFloat(h & 0xFF)/255, alpha: a)
}

// Temperature gradient stops (match Theme.temp): green → yellow → orange → red.
let stops: [(CGFloat, NSColor)] = [
    (0.00, hex(0x3FB950)), (0.34, hex(0xE3B341)), (0.62, hex(0xF0883E)), (1.00, hex(0xF85149)),
]
func tempColor(_ f: CGFloat) -> NSColor {
    let x = max(0, min(1, f))
    if x <= stops.first!.0 { return stops.first!.1 }
    if x >= stops.last!.0 { return stops.last!.1 }
    for i in 0..<stops.count-1 {
        let (a, ca) = stops[i], (b, cb) = stops[i+1]
        if x >= a && x <= b {
            let t = (x - a)/(b - a)
            return NSColor(srgbRed: ca.redComponent + (cb.redComponent-ca.redComponent)*t,
                           green: ca.greenComponent + (cb.greenComponent-ca.greenComponent)*t,
                           blue: ca.blueComponent + (cb.blueComponent-ca.blueComponent)*t, alpha: 1)
        }
    }
    return stops.last!.1
}

func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
    let img = NSImage(size: image.size)
    img.lockFocus()
    image.draw(at: .zero, from: NSRect(origin: .zero, size: image.size), operation: .sourceOver, fraction: 1)
    color.set()
    NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
    img.unlockFocus()
    return img
}

let out = NSImage(size: NSSize(width: S, height: S))
out.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// 1) Squircle instrument body with a top→bottom dark gradient + bezel.
let margin: CGFloat = 96
let bodyRect = NSRect(x: margin, y: margin, width: S - 2*margin, height: S - 2*margin)
let radius = bodyRect.width * 0.2237
let squircle = NSBezierPath(roundedRect: bodyRect, xRadius: radius, yRadius: radius)
ctx.saveGState()
squircle.addClip()
let bg = NSGradient(colors: [hex(0x222A34), hex(0x0E1116)])!
bg.draw(in: bodyRect, angle: -90)
ctx.restoreGState()
hex(0x2A313B).setStroke()
squircle.lineWidth = 5
squircle.stroke()

let center = NSPoint(x: S/2, y: S/2)

// 2) Temperature gauge: 270° arc (gap at the bottom), green→red, drawn as many
//    short colored segments so no conic-gradient API is required.
let ringRadius: CGFloat = 262
let ringWidth: CGFloat = 88
let startDeg: CGFloat = 225, sweep: CGFloat = 270   // clockwise from lower-left to lower-right
let N = 240
// faint track underneath for depth
let track = NSBezierPath()
track.appendArc(withCenter: center, radius: ringRadius, startAngle: startDeg - sweep, endAngle: startDeg)
track.lineWidth = ringWidth + 6
track.lineCapStyle = .round
hex(0x0B0E13).setStroke()
track.stroke()
for i in 0..<N {
    let f0 = CGFloat(i)/CGFloat(N), f1 = CGFloat(i+1)/CGFloat(N)
    let a0 = startDeg - f0*sweep, a1 = startDeg - f1*sweep
    let seg = NSBezierPath()
    seg.appendArc(withCenter: center, radius: ringRadius, startAngle: a1, endAngle: a0, clockwise: false)
    seg.lineWidth = ringWidth
    seg.lineCapStyle = (i == 0 || i == N-1) ? .round : .butt
    tempColor(f0).setStroke()
    seg.stroke()
}

// 3) Teal operating-point dot riding the arc (the app's live "working point").
let dotF: CGFloat = 0.60
let dotAngle = (startDeg - dotF*sweep) * .pi/180
let dotPos = NSPoint(x: center.x + ringRadius*cos(dotAngle), y: center.y + ringRadius*sin(dotAngle))
let halo = NSBezierPath(ovalIn: NSRect(x: dotPos.x-46, y: dotPos.y-46, width: 92, height: 92))
hex(0x37C2C4, 0.28).setFill(); halo.fill()
let dot = NSBezierPath(ovalIn: NSRect(x: dotPos.x-30, y: dotPos.y-30, width: 60, height: 60))
hex(0x37C2C4).setFill(); dot.fill()
hex(0xFFFFFF, 0.95).setStroke(); dot.lineWidth = 7; dot.stroke()

// 4) Thermometer glyph, centered inside the ring.
let cfg = NSImage.SymbolConfiguration(pointSize: 300, weight: .semibold)
if let sym = NSImage(systemSymbolName: "thermometer.medium", accessibilityDescription: nil)?
    .withSymbolConfiguration(cfg) {
    let t = tinted(sym, hex(0xEEF2F7))
    let sz = t.size
    let r = NSRect(x: center.x - sz.width/2, y: center.y - sz.height/2, width: sz.width, height: sz.height)
    t.draw(in: r, from: NSRect(origin: .zero, size: sz), operation: .sourceOver, fraction: 1)
}

out.unlockFocus()

// Export PNG.
guard let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("failed to render icon\n".data(using: .utf8)!); exit(1)
}
let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
try! png.write(to: URL(fileURLWithPath: path))
print("wrote \(path)")
