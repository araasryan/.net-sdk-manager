#!/usr/bin/env swift
// Renders the app icon (stacked "version layers" with a download arrow) into Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift
import AppKit

let fm = FileManager.default
let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

/// A flat isometric diamond (one "layer") centred at (cx, cy).
func diamond(_ cx: CGFloat, _ cy: CGFloat, _ w: CGFloat, _ h: CGFloat, radius r: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let pts = [CGPoint(x: cx, y: cy + h / 2), CGPoint(x: cx + w / 2, y: cy),
               CGPoint(x: cx, y: cy - h / 2), CGPoint(x: cx - w / 2, y: cy)]
    p.move(to: CGPoint(x: (pts[3].x + pts[0].x) / 2, y: (pts[3].y + pts[0].y) / 2))
    for i in 0..<4 { p.addArc(tangent1End: pts[i], tangent2End: pts[(i + 1) % 4], radius: r) }
    p.closeSubpath()
    return p
}

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s / 1024, y: s / 1024)

    // macOS icon grid: 824pt body centred in a 1024 canvas, continuous-ish corner radius.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(bodyPath); ctx.setFillColor(color(0x3b1f8f)); ctx.fillPath()
    ctx.restoreGState()

    // Background gradient
    ctx.saveGState()
    ctx.addPath(bodyPath); ctx.clip()
    let bg = CGGradient(colorsSpace: nil, colors: [color(0x8a5cf6), color(0x5b2fd1), color(0x2e1a7a)] as CFArray,
                        locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 300, y: 924), end: CGPoint(x: 724, y: 100), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // soft top highlight
    let hl = CGGradient(colorsSpace: nil, colors: [color(0xffffff, 0.22), color(0xffffff, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(hl, startCenter: CGPoint(x: 512, y: 960), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 960), endRadius: 620, options: [])
    ctx.restoreGState()

    // Three stacked layers = installed versions
    let cx: CGFloat = 470, w: CGFloat = 470, h: CGFloat = 272
    let layers: [(CGFloat, UInt32, CGFloat)] = [(360, 0xffffff, 0.40), (455, 0xffffff, 0.68), (550, 0xffffff, 1.0)]
    for (cy, c, a) in layers {
        // side thickness
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 18, color: color(0x140a3d, 0.45))
        ctx.addPath(diamond(cx, cy - 22, w, h, radius: 34)); ctx.setFillColor(color(0xc9b8ff, a)); ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(diamond(cx, cy, w, h, radius: 34)); ctx.setFillColor(color(c, a)); ctx.fillPath()
    }

    // Download badge, bottom-right
    let badgeC = CGPoint(x: 712, y: 300), br: CGFloat = 132
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: color(0x000000, 0.35))
    ctx.addEllipse(in: CGRect(x: badgeC.x - br, y: badgeC.y - br, width: br * 2, height: br * 2))
    ctx.setFillColor(color(0x22c55e)); ctx.fillPath()
    ctx.restoreGState()
    ctx.setStrokeColor(color(0xffffff)); ctx.setLineWidth(30); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: badgeC.x, y: badgeC.y + 66)); ctx.addLine(to: CGPoint(x: badgeC.x, y: badgeC.y - 58))
    ctx.move(to: CGPoint(x: badgeC.x - 54, y: badgeC.y - 6)); ctx.addLine(to: CGPoint(x: badgeC.x, y: badgeC.y - 60))
    ctx.addLine(to: CGPoint(x: badgeC.x + 54, y: badgeC.y - 6))
    ctx.strokePath()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let res = root.appendingPathComponent("Resources")
try fm.createDirectory(at: res, withIntermediateDirectories: true)
try render(1024).write(to: res.appendingPathComponent("AppIcon.png"))

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", res.appendingPathComponent("AppIcon.icns").path]
try p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
