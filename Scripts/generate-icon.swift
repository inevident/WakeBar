#!/usr/bin/env swift

import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: generate-icon.swift <output.iconset>\n", stderr)
    exit(64)
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(
    at: outputDirectory,
    withIntermediateDirectories: true
)

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

func makeIcon(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "WakeBarIcon", code: 1)
    }

    bitmap.size = NSSize(width: pixels, height: pixels)

    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "WakeBarIcon", code: 2)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context

    let size = CGFloat(pixels)
    let canvas = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    canvas.fill()

    let inset = size * 0.055
    let tileRect = canvas.insetBy(dx: inset, dy: inset)
    let tile = NSBezierPath(
        roundedRect: tileRect,
        xRadius: size * 0.225,
        yRadius: size * 0.225
    )
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.05, green: 0.78, blue: 0.88, alpha: 1),
        NSColor(calibratedRed: 0.13, green: 0.31, blue: 0.91, alpha: 1),
        NSColor(calibratedRed: 0.08, green: 0.12, blue: 0.30, alpha: 1)
    ])
    gradient?.draw(in: tile, angle: -52)

    let glowRect = NSRect(
        x: size * 0.12,
        y: size * 0.47,
        width: size * 0.68,
        height: size * 0.68
    )
    let glow = NSBezierPath(ovalIn: glowRect)
    NSColor.white.withAlphaComponent(0.13).setFill()
    glow.fill()

    let ringRect = canvas.insetBy(dx: size * 0.245, dy: size * 0.245)
    let ring = NSBezierPath(ovalIn: ringRect)
    ring.lineWidth = max(1, size * 0.072)
    ring.lineCapStyle = .round
    NSColor.white.withAlphaComponent(0.96).setStroke()
    ring.stroke()

    let stem = NSBezierPath()
    stem.move(to: NSPoint(x: size * 0.5, y: size * 0.72))
    stem.line(to: NSPoint(x: size * 0.5, y: size * 0.49))
    stem.lineWidth = max(1, size * 0.075)
    stem.lineCapStyle = .round
    NSColor.white.setStroke()
    stem.stroke()

    let highlight = NSBezierPath()
    highlight.move(to: NSPoint(x: size * 0.23, y: size * 0.79))
    highlight.curve(
        to: NSPoint(x: size * 0.72, y: size * 0.84),
        controlPoint1: NSPoint(x: size * 0.37, y: size * 0.91),
        controlPoint2: NSPoint(x: size * 0.58, y: size * 0.91)
    )
    highlight.lineWidth = max(1, size * 0.018)
    highlight.lineCapStyle = .round
    NSColor.white.withAlphaComponent(0.2).setStroke()
    highlight.stroke()

    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "WakeBarIcon", code: 3)
    }

    return data
}

for variant in variants {
    let data = try makeIcon(pixels: variant.pixels)
    try data.write(to: outputDirectory.appendingPathComponent(variant.name))
}
