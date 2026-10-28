#!/usr/bin/env swift
// Draws Bekitzur's icons, a speech bubble holding a waveform, into App/Resources: AppIcon.icns and the menu bar's
// template images. Run it after changing the drawing:
//
//   swift scripts/make-icon.swift [preview.png]
//
// With a path, it also writes a sheet of the icon at several sizes and the menu bar images on light and dark bars.
import AppKit

let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "App/Resources")
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// A rectangle with Apple's continuous corners, which start curving 1.528665 radii before the corner. The radius can be at
/// most a third of the shorter side.
func continuousRect(_ rect: CGRect, radius r: CGFloat) -> CGPath {
    let a: CGFloat = 1.52866483
    let corners: [(CGPoint, CGVector, CGVector)] = [
        (CGPoint(x: rect.maxX, y: rect.maxY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: -1)),
        (CGPoint(x: rect.maxX, y: rect.minY), CGVector(dx: 0, dy: -1), CGVector(dx: -1, dy: 0)),
        (CGPoint(x: rect.minX, y: rect.minY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: 1)),
        (CGPoint(x: rect.minX, y: rect.maxY), CGVector(dx: 0, dy: 1), CGVector(dx: 1, dy: 0)),
    ]
    let path = CGMutablePath()
    path.move(to: CGPoint(x: rect.minX + a * r, y: rect.maxY))
    for (corner, toward, away) in corners {
        // Back from the corner along the edge arriving at it, then out along the edge leaving it.
        func p(_ back: CGFloat, _ out: CGFloat) -> CGPoint {
            CGPoint(x: corner.x - toward.dx * back * r + away.dx * out * r, y: corner.y - toward.dy * back * r + away.dy * out * r)
        }
        path.addLine(to: p(a, 0))
        path.addCurve(to: p(0.63149399, 0.07491176), control1: p(1.08849323, 0), control2: p(0.86840689, 0))
        path.addCurve(to: p(0.07491176, 0.63149399), control1: p(0.37282392, 0.16906013), control2: p(0.16906013, 0.37282392))
        path.addCurve(to: p(0, a), control1: p(0, 0.86840689), control2: p(0, 1.08849323))
    }
    path.closeSubpath()
    return path
}

func bar(centerX: CGFloat, centerY: CGFloat, width: CGFloat, height: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: centerX - width / 2, y: centerY - height / 2, width: width, height: height),
           cornerWidth: width / 2, cornerHeight: width / 2, transform: nil)
}

func render(pixels: Int, units: CGFloat, draw: (CGContext, CGFloat) -> Void) -> CGImage {
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(pixels) / units
    context.scaleBy(x: scale, y: scale)
    draw(context, scale)
    return context.makeImage()!
}

func png(_ image: CGImage) -> Data {
    NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

// MARK: The app icon, on Apple's 1024-point grid: an 824-point tile with 100 points around it for the shadow.

let tile = continuousRect(CGRect(x: 100, y: 100, width: 824, height: 824), radius: 185.4)
let body = CGRect(x: 232, y: 330, width: 560, height: 452)
let panel = body.insetBy(dx: 92, dy: 92)

func tail() -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 600, y: 352))
    path.addLine(to: CGPoint(x: 708, y: 352))
    path.addQuadCurve(to: CGPoint(x: 744, y: 246), control: CGPoint(x: 718, y: 296))
    path.addQuadCurve(to: CGPoint(x: 600, y: 352), control: CGPoint(x: 684, y: 290))
    path.closeSubpath()
    return path
}

func drawTileGradient(_ c: CGContext) {
    let gradient = CGGradient(colorsSpace: sRGB, colors: [color(0xA472F5), color(0x6A47E3), color(0x2A209C)] as CFArray, locations: [0, 0.45, 1])!
    c.drawLinearGradient(gradient, start: CGPoint(x: 700, y: 924), end: CGPoint(x: 330, y: 100), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func drawIcon(_ c: CGContext, _ scale: CGFloat, simple: Bool) {
    c.saveGState()
    if !simple { c.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 28 * scale, color: color(0x000000, 0.32)) }
    c.addPath(tile)
    c.setFillColor(color(0x2A209C))
    c.fillPath()
    c.restoreGState()

    c.saveGState()
    c.addPath(tile)
    c.clip()
    drawTileGradient(c)
    if !simple {
        let shine = CGGradient(colorsSpace: sRGB, colors: [color(0xFFFFFF, 0.24), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
        c.drawLinearGradient(shine, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
    }
    c.restoreGState()

    let bubble = continuousRect(body, radius: 140)
    c.saveGState()
    if !simple { c.setShadow(offset: CGSize(width: 0, height: -14 * scale), blur: 30 * scale, color: color(0x10083F, 0.35)) }
    c.beginTransparencyLayer(auxiliaryInfo: nil)
    c.setFillColor(color(0xFFFFFF))
    c.addPath(bubble)
    c.addPath(tail())
    c.fillPath()
    c.endTransparencyLayer()
    c.restoreGState()

    if simple {
        c.setFillColor(color(0x3B2BB5))
        for (offset, height) in [(-110.0, 150.0), (0, 270), (110, 150)] {
            c.addPath(bar(centerX: 512 + offset, centerY: body.midY, width: 72, height: height))
        }
        c.fillPath()
        return
    }

    // The bubble's window shows the tile behind it.
    c.saveGState()
    c.addPath(continuousRect(panel, radius: 80))
    c.clip()
    drawTileGradient(c)
    let inner = CGGradient(colorsSpace: sRGB, colors: [color(0x10083F, 0.28), color(0x10083F, 0)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(inner, start: CGPoint(x: 512, y: panel.maxY), end: CGPoint(x: 512, y: panel.maxY - 40), options: [])
    c.restoreGState()

    c.setFillColor(color(0xCDBDFF))
    for (index, height) in [86.0, 150, 214, 150, 86].enumerated() {
        c.addPath(bar(centerX: 512 + CGFloat(index - 2) * 62, centerY: panel.midY, width: 36, height: height))
    }
    c.fillPath()
}

// MARK: The menu bar symbol, on an 18-point grid: the bubble's outline with three bars, and a dot when there's something
// to review. Template images are black on clear; macOS colors them for the menu bar.

func drawMenuBarSymbol(_ c: CGContext, badged: Bool) {
    let outer = CGRect(x: 1.4, y: 4.2, width: 15.2, height: 11.6)
    let tip = CGMutablePath()
    tip.move(to: CGPoint(x: 10.2, y: 5.2))
    tip.addLine(to: CGPoint(x: 13.2, y: 5.2))
    tip.addQuadCurve(to: CGPoint(x: 14.6, y: 1.4), control: CGPoint(x: 13.6, y: 3.2))
    tip.addQuadCurve(to: CGPoint(x: 10.2, y: 5.2), control: CGPoint(x: 12.6, y: 3.0))
    tip.closeSubpath()

    c.setFillColor(color(0x000000))
    c.addPath(continuousRect(outer, radius: 3.6))
    c.addPath(tip)
    c.fillPath()
    c.setBlendMode(.clear)
    c.addPath(continuousRect(outer.insetBy(dx: 1.6, dy: 1.6), radius: 2.2))
    c.fillPath()
    c.setBlendMode(.normal)
    for (offset, height) in [(-3.0, 3.0), (0, 5.6), (3, 3.0)] {
        c.addPath(bar(centerX: outer.midX + offset, centerY: outer.midY, width: 1.6, height: height))
    }
    c.fillPath()
    if badged {
        c.setBlendMode(.clear)
        c.addEllipse(in: CGRect(x: 11.6, y: 11.2, width: 7.2, height: 7.2))
        c.fillPath()
        c.setBlendMode(.normal)
        c.addEllipse(in: CGRect(x: 12.8, y: 12.4, width: 4.8, height: 4.8))
        c.fillPath()
    }
}

// MARK: Writing the files.

try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
let iconset = FileManager.default.temporaryDirectory.appending(path: "Bekitzur-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try png(render(pixels: pixels, units: 1024) { c, s in drawIcon(c, s, simple: pixels < 64) }).write(to: iconset.appending(path: name))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", "-o", resources.appending(path: "AppIcon.icns").path, iconset.path]
try iconutil.run()
iconutil.waitUntilExit()
try FileManager.default.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }

for badged in [false, true] {
    let name = badged ? "MenuBarBadgedTemplate" : "MenuBarTemplate"
    try png(render(pixels: 18, units: 18) { c, _ in drawMenuBarSymbol(c, badged: badged) }).write(to: resources.appending(path: "\(name).png"))
    try png(render(pixels: 36, units: 18) { c, _ in drawMenuBarSymbol(c, badged: badged) }).write(to: resources.appending(path: "\(name)@2x.png"))
}
print("Wrote AppIcon.icns, MenuBarTemplate.png, and MenuBarBadgedTemplate.png (with @2x) to \(resources.path)")

// MARK: The preview sheet.

if CommandLine.arguments.count > 1 {
    let width = 1600, height = 760
    let sheet = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    sheet.setFillColor(color(0xF2F2F5))
    sheet.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
    sheet.setFillColor(color(0x1E1E22))
    sheet.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
    // The icon at its real sizes on both backgrounds, then the menu bar images at four times their size, tinted.
    var x = 30
    for pixels in [512, 128, 64, 32, 16] {
        let image = render(pixels: pixels, units: 1024) { c, s in drawIcon(c, s, simple: pixels < 64) }
        let shown = min(pixels, 300)
        sheet.draw(image, in: CGRect(x: x, y: 30, width: shown, height: shown))
        sheet.draw(image, in: CGRect(x: x, y: height / 2 + 30, width: shown, height: shown))
        x += shown + 40
    }
    for (row, tint) in [(0, color(0x000000, 0.85)), (1, color(0xFFFFFF, 0.9))] {
        var mx = x + 20
        for badged in [false, true] {
            let mask = render(pixels: 72, units: 18) { c, _ in drawMenuBarSymbol(c, badged: badged) }
            let frame = CGRect(x: mx, y: row * height / 2 + 120, width: 72, height: 72)
            sheet.saveGState()
            sheet.clip(to: frame, mask: mask)
            sheet.setFillColor(tint)
            sheet.fill(frame)
            sheet.restoreGState()
            mx += 110
        }
    }
    try png(sheet.makeImage()!).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    print("Wrote the preview to \(CommandLine.arguments[1])")
}
