// Renders the LanDetector app icon into an asset catalog.
// Usage: swift Scripts/make_icon.swift LanDetector/Assets.xcassets
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "LanDetector/Assets.xcassets"
let iconSet = URL(fileURLWithPath: outDir).appendingPathComponent("AppIcon.appiconset")
try? FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let k = s / 1024
    // macOS icon grid: 824pt body centred in 1024, continuous corner radius ≈ 185.
    let body = CGRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    let path = CGPath(roundedRect: body, cornerWidth: 185 * k, cornerHeight: 185 * k, transform: nil)

    // Drop shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 24 * k, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(path)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let bg = CGGradient(colorsSpace: space, colors: [
        NSColor(red: 0.07, green: 0.12, blue: 0.32, alpha: 1).cgColor,
        NSColor(red: 0.18, green: 0.25, blue: 0.78, alpha: 1).cgColor,
        NSColor(red: 0.42, green: 0.32, blue: 0.95, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 0.6, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: body.minX, y: body.minY), end: CGPoint(x: body.maxX, y: body.maxY), options: [])

    let center = CGPoint(x: 512 * k, y: 470 * k)
    // Radar sweep.
    ctx.saveGState()
    let sweep = CGMutablePath()
    sweep.move(to: center)
    sweep.addArc(center: center, radius: 420 * k, startAngle: .pi * 0.18, endAngle: .pi * 0.62, clockwise: false)
    sweep.closeSubpath()
    ctx.addPath(sweep)
    ctx.clip()
    let sweepGradient = CGGradient(colorsSpace: space, colors: [
        NSColor(red: 0.45, green: 0.95, blue: 0.95, alpha: 0.55).cgColor,
        NSColor(red: 0.45, green: 0.95, blue: 0.95, alpha: 0.0).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(sweepGradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: 420 * k, options: [])
    ctx.restoreGState()

    // Rings.
    for (i, r) in [130.0, 230.0, 330.0].enumerated() {
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.32 - Double(i) * 0.07).cgColor)
        ctx.setLineWidth(10 * k)
        ctx.strokeEllipse(in: CGRect(x: center.x - r * k, y: center.y - r * k, width: 2 * r * k, height: 2 * r * k))
    }

    // Device nodes with links to the centre.
    let nodes: [(CGFloat, CGFloat, CGFloat, NSColor)] = [
        (-0.55, 230, 34, NSColor(red: 0.35, green: 0.95, blue: 0.62, alpha: 1)),
        (0.42, 330, 30, NSColor(red: 1.0, green: 0.72, blue: 0.25, alpha: 1)),
        (1.05, 230, 30, NSColor(red: 0.45, green: 0.95, blue: 0.95, alpha: 1)),
        (2.35, 330, 28, NSColor(red: 1.0, green: 0.45, blue: 0.6, alpha: 1)),
        (3.4, 130, 26, NSColor(red: 0.75, green: 0.8, blue: 1.0, alpha: 1)),
    ]
    for (angle, radius, _, _) in nodes {
        let p = CGPoint(x: center.x + cos(angle) * radius * k, y: center.y + sin(angle) * radius * k)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.25).cgColor)
        ctx.setLineWidth(6 * k)
        ctx.move(to: center)
        ctx.addLine(to: p)
        ctx.strokePath()
    }
    for (angle, radius, size, color) in nodes {
        let p = CGPoint(x: center.x + cos(angle) * radius * k, y: center.y + sin(angle) * radius * k)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 28 * k, color: color.withAlphaComponent(0.9).cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: CGRect(x: p.x - size * k, y: p.y - size * k, width: 2 * size * k, height: 2 * size * k))
        ctx.restoreGState()
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        let hs = size * 0.38
        ctx.fillEllipse(in: CGRect(x: p.x - hs * k - size * 0.25 * k, y: p.y - hs * k + size * 0.25 * k, width: 2 * hs * k, height: 2 * hs * k))
    }

    // Centre: this Mac.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 30 * k, color: NSColor.white.withAlphaComponent(0.8).cgColor)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillEllipse(in: CGRect(x: center.x - 48 * k, y: center.y - 48 * k, width: 96 * k, height: 96 * k))
    ctx.restoreGState()
    ctx.setFillColor(NSColor(red: 0.2, green: 0.3, blue: 0.85, alpha: 1).cgColor)
    ctx.fillEllipse(in: CGRect(x: center.x - 22 * k, y: center.y - 22 * k, width: 44 * k, height: 44 * k))

    // Top gloss.
    let gloss = CGGradient(colorsSpace: space, colors: [
        NSColor.white.withAlphaComponent(0.22).cgColor, NSColor.white.withAlphaComponent(0).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gloss, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.midY + 80 * k), options: [])
    ctx.restoreGState()

    // Hairline border.
    ctx.addPath(path)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
    ctx.setLineWidth(3 * k)
    ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for (size, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let px = size * scale
    let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
    try! render(px).write(to: iconSet.appendingPathComponent(name))
    images.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: iconSet.appendingPathComponent("Contents.json"))
print("Wrote \(iconSet.path)")
