#!/usr/bin/env swift
// Native Core Graphics renderer for the macXcapture app icon.
//
// Same visual language as the macXserver icon (concept1-aqua-dock):
// a glossy rounded-rect with a top shine, drawn here in red instead
// of blue, with the word "XTAP" replacing the white X. We draw the
// text as outlined glyph paths (not SVG <text>, which NSImage won't
// render) so it's font-independent and crisp at every size.
//
// Usage:
//   ./render-xtap-icon.swift <out.png> <size>          single PNG
//   ./render-xtap-icon.swift --appiconset <out-dir>    full icon set

import AppKit
import Foundation

// Everything below is authored in a 1024x1024 design space; the
// context is scaled so the same constants render at any pixel size.
let DESIGN: CGFloat = 1024

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(deviceRed: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: a)
}

/// Outlined glyph path for a string, laid out on a single line in
/// text space (y-up, baseline at 0). Returned in its natural metrics;
/// the caller scales + centers it.
func glyphPath(_ text: String, font: NSFont) -> CGPath {
    let attr = NSAttributedString(string: text, attributes: [.font: font])
    let line = CTLineCreateWithAttributedString(attr)
    let runs = CTLineGetGlyphRuns(line) as! [CTRun]
    let combined = CGMutablePath()
    for run in runs {
        let count = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRangeMake(0, count), &glyphs)
        CTRunGetPositions(run, CFRangeMake(0, count), &positions)
        let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
        for i in 0..<count {
            guard let gp = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) else { continue }
            let t = CGAffineTransform(translationX: positions[i].x, y: positions[i].y)
            combined.addPath(gp, transform: t)
        }
    }
    return combined
}

func heavyFont(size: CGFloat) -> NSFont {
    for name in ["Arial-Black", "Helvetica-Bold", "ArialMT"] {
        if let f = NSFont(name: name, size: size) { return f }
    }
    return NSFont.systemFont(ofSize: size, weight: .black)
}

func drawIcon(into ctx: CGContext, pixelSize: CGFloat) {
    ctx.saveGState()
    ctx.scaleBy(x: pixelSize / DESIGN, y: pixelSize / DESIGN)

    let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsCtx

    let bounds = NSRect(x: 0, y: 0, width: DESIGN, height: DESIGN)
    let radius: CGFloat = 228
    let bgPath = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)

    // Background: red vertical gradient (light at top -> dark at
    // bottom), mirroring the blue server icon's luminance ramp.
    let bg = NSGradient(colors: [rgb(0xF2, 0x76, 0x6F),
                                 rgb(0xD6, 0x2E, 0x2E),
                                 rgb(0x85, 0x0E, 0x0E)],
                        atLocations: [0.0, 0.45, 1.0],
                        colorSpace: .deviceRGB)!
    bg.draw(in: bgPath, angle: -90)

    // Top shine: white highlight fading out by ~60% down. Clip to the
    // rounded rect so it follows the corners.
    ctx.saveGState()
    bgPath.addClip()
    let shine = NSGradient(colors: [NSColor.white.withAlphaComponent(0.35),
                                    NSColor.white.withAlphaComponent(0.0)],
                           atLocations: [0.0, 0.6],
                           colorSpace: .deviceRGB)!
    shine.draw(in: bounds, angle: -90)
    ctx.restoreGState()

    // "XTAP" as outlined glyphs, scaled to fit and centered.
    let raw = glyphPath("XTAP", font: heavyFont(size: 256))
    let bb = raw.boundingBoxOfPath
    let targetW: CGFloat = 864
    let targetH: CGFloat = 420
    let scale = min(targetW / bb.width, targetH / bb.height)
    var t = CGAffineTransform(scaleX: scale, y: scale)
    let scaledBB = bb.applying(t)
    t = t.concatenating(CGAffineTransform(
        translationX: (DESIGN - scaledBB.width) / 2 - scaledBB.minX,
        y: (DESIGN - scaledBB.height) / 2 - scaledBB.minY))
    let textPath = raw.copy(using: &t)!

    // Drop shadow + white fill in one pass.
    ctx.saveGState()
    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -8)
    shadow.shadowBlurRadius = 10
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
    shadow.set()
    ctx.addPath(textPath)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Subtle white -> warm-light gradient over the glyphs (no shadow),
    // matching the server X's gentle top-light sheen.
    ctx.saveGState()
    ctx.addPath(textPath)
    ctx.clip()
    let textGrad = NSGradient(starting: NSColor.white, ending: rgb(0xEF, 0xD9, 0xD9))!
    textGrad.draw(in: NSRect(x: 0, y: scaledBB.minY,
                             width: DESIGN, height: scaledBB.height), angle: -90)
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    ctx.restoreGState()
}

func renderPNG(outPath: String, size: Int) throws {
    let s = CGFloat(size)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32) else {
        throw NSError(domain: "render-xtap", code: 1)
    }
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else {
        throw NSError(domain: "render-xtap", code: 2)
    }
    drawIcon(into: ctx, pixelSize: s)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "render-xtap", code: 3)
    }
    try data.write(to: URL(fileURLWithPath: outPath))
}

let appIconSizes: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

let args = CommandLine.arguments
if args.count == 3 && args[1] == "--appiconset" {
    let dir = args[2]
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for (name, px) in appIconSizes {
        try renderPNG(outPath: dir + "/" + name, size: px)
        print("  \(name) (\(px)px)")
    }
} else if args.count == 3 {
    try renderPNG(outPath: args[1], size: Int(args[2]) ?? 512)
    print("wrote \(args[1])")
} else {
    print("""
    usage:
      render-xtap-icon.swift <out.png> <size>
      render-xtap-icon.swift --appiconset <out-dir>
    """)
    exit(2)
}
