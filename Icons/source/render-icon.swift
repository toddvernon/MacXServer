#!/usr/bin/env swift
// Tiny SVG → PNG rasterizer that uses NSImage's built-in SVG
// support (macOS 14+). Used to regenerate the AppIcon.appiconset
// PNGs from the source SVG when the icon design changes.
//
// Usage: ./render-icon.swift <input.svg> <output.png> <size>
//   e.g. ./render-icon.swift concept1-aqua-dock.svg out.png 512
//
// Or batch via the helper at the bottom: comment out main and
// call renderAppIconSet(svg:into:).

import AppKit
import Foundation

func renderSVG(svgPath: String, outPath: String, size: Int) throws {
    guard let img = NSImage(contentsOfFile: svgPath) else {
        throw NSError(domain: "render-icon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "could not load \(svgPath)"])
    }
    img.size = NSSize(width: size, height: size)

    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 32
    ) else {
        throw NSError(domain: "render-icon", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "could not allocate bitmap"])
    }
    rep.size = NSSize(width: size, height: size)

    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
        throw NSError(domain: "render-icon", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "could not create context"])
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    img.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
             from: NSRect(x: 0, y: 0, width: img.size.width, height: img.size.height),
             operation: .copy, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "render-icon", code: 4,
                      userInfo: [NSLocalizedDescriptionKey: "PNG encode failed"])
    }
    try data.write(to: URL(fileURLWithPath: outPath))
}

// Sizes the macOS AppIcon.appiconset expects.
let appIconSizes: [(name: String, pixels: Int)] = [
    ("icon_16x16.png",       16),
    ("icon_16x16@2x.png",    32),
    ("icon_32x32.png",       32),
    ("icon_32x32@2x.png",    64),
    ("icon_128x128.png",    128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png",    256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png",    512),
    ("icon_512x512@2x.png", 1024),
]

func renderAppIconSet(svgPath: String, intoDir: String) throws {
    let fm = FileManager.default
    try fm.createDirectory(atPath: intoDir, withIntermediateDirectories: true)
    for (name, pixels) in appIconSizes {
        let out = intoDir + "/" + name
        try renderSVG(svgPath: svgPath, outPath: out, size: pixels)
        print("  \(name) (\(pixels)px)")
    }
}

// CLI dispatch: <svg> <out.png> <size>
//           or: --appiconset <svg> <dir>
let args = CommandLine.arguments
if args.count == 4 && args[1] == "--appiconset" {
    try renderAppIconSet(svgPath: args[2], intoDir: args[3])
} else if args.count == 4 {
    try renderSVG(svgPath: args[1], outPath: args[2], size: Int(args[3]) ?? 512)
} else {
    print("""
    usage:
      render-icon.swift <input.svg> <output.png> <size>
      render-icon.swift --appiconset <input.svg> <output-dir>
    """)
    exit(2)
}
