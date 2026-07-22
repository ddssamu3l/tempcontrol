// Generates AppIcon.iconset — a black rounded square with an amber
// thermometer, matching the app's TUI aesthetic.
// Usage: swift scripts/makeicon.swift <output-dir>

import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build"
let iconset = "\(outDir)/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

let amber = NSColor(calibratedRed: 1.0, green: 0.70, blue: 0.30, alpha: 1)

func drawIcon(_ s: CGFloat) {
    // Rounded-square plate on the standard macOS icon grid (~80% of canvas).
    let inset = s * 0.10
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let plate = NSBezierPath(roundedRect: rect, xRadius: s * 0.185, yRadius: s * 0.185)
    NSColor.black.setFill()
    plate.fill()
    NSColor(white: 0.30, alpha: 1).setStroke()
    plate.lineWidth = max(1, s * 0.01)
    plate.stroke()

    let lineW = max(1, s * 0.022)

    // Thermometer tube.
    let tubeW = s * 0.115
    let bulbR = s * 0.105
    let bulbC = NSPoint(x: s * 0.42, y: rect.minY + s * 0.185)
    let tubeTop = rect.maxY - s * 0.13
    let tubeRect = NSRect(x: bulbC.x - tubeW / 2, y: bulbC.y, width: tubeW, height: tubeTop - bulbC.y)
    let tube = NSBezierPath(roundedRect: tubeRect, xRadius: tubeW / 2, yRadius: tubeW / 2)
    NSColor.white.setStroke()
    tube.lineWidth = lineW
    tube.stroke()

    // Mercury column + bulb in amber.
    let mercH = (tubeTop - bulbC.y) * 0.58
    let merc = NSBezierPath(
        roundedRect: NSRect(x: bulbC.x - tubeW * 0.26, y: bulbC.y, width: tubeW * 0.52, height: mercH),
        xRadius: tubeW * 0.26, yRadius: tubeW * 0.26)
    amber.setFill()
    merc.fill()
    let bulb = NSBezierPath(ovalIn: NSRect(x: bulbC.x - bulbR, y: bulbC.y - bulbR,
                                           width: bulbR * 2, height: bulbR * 2))
    amber.setFill()
    bulb.fill()
    NSColor.white.setStroke()
    bulb.lineWidth = lineW
    bulb.stroke()

    // Scale ticks to the right of the tube, TUI style.
    NSColor(white: 0.75, alpha: 1).setStroke()
    let tickX = bulbC.x + tubeW * 1.1
    let tickTop = tubeTop - tubeW * 0.3
    let tickBottom = bulbC.y + bulbR * 1.6
    for i in 0..<5 {
        let y = tickBottom + (tickTop - tickBottom) * CGFloat(i) / 4
        let long = i % 2 == 0
        let tick = NSBezierPath()
        tick.move(to: NSPoint(x: tickX, y: y))
        tick.line(to: NSPoint(x: tickX + (long ? s * 0.10 : s * 0.06), y: y))
        tick.lineWidth = lineW * 0.8
        tick.stroke()
    }
}

func writePNG(pixels: Int, name: String) {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: rep)
    else { fatalError("bitmap setup failed") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    drawIcon(CGFloat(pixels))
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("png failed") }
    try! data.write(to: URL(fileURLWithPath: "\(iconset)/\(name).png"))
}

for base in [16, 32, 128, 256, 512] {
    writePNG(pixels: base, name: "icon_\(base)x\(base)")
    writePNG(pixels: base * 2, name: "icon_\(base)x\(base)@2x")
}
print("wrote \(iconset)")
