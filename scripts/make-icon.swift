#!/usr/bin/env swift
// Renders PR Float's app icon into an .iconset, ready for `iconutil`.
// Kept as source rather than a checked-in binary so the mark can be tweaked.

import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.iconset>\n".utf8))
    exit(1)
}

let outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

/// macOS icons sit on a rounded-rect plate with a consistent inset.
func render(size: CGFloat) -> Data? {
    // Drawing into a bitmap rep directly, rather than via `NSImage.lockFocus`, so this
    // runs headlessly in a build script with no window server attached.
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size),
        pixelsHigh: Int(size),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        return nil
    }
    bitmap.size = NSSize(width: size, height: size)

    guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    defer { NSGraphicsContext.restoreGraphicsState() }

    graphicsContext.cgContext.setShouldAntialias(true)

    let inset = size * 0.06
    let plate = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let corner = plate.width * 0.2237

    let platePath = NSBezierPath(roundedRect: plate, xRadius: corner, yRadius: corner)

    // Deep indigo→violet plate, legible on both light and dark desktops.
    let gradient = NSGradient(
        colors: [
            NSColor(calibratedRed: 0.36, green: 0.33, blue: 0.85, alpha: 1),
            NSColor(calibratedRed: 0.22, green: 0.20, blue: 0.58, alpha: 1)
        ]
    )
    gradient?.draw(in: platePath, angle: -90)

    // Checklist mark: three rows, the first two ticked.
    let unit = plate.width
    let lineWidth = max(1, unit * 0.055)
    let rowSpacing = unit * 0.19
    let firstRowY = plate.midY + rowSpacing
    let boxSize = unit * 0.15
    let boxX = plate.minX + unit * 0.20
    let barX = boxX + boxSize + unit * 0.09
    let barWidth = unit * 0.30

    NSColor.white.setStroke()
    NSColor.white.setFill()

    for row in 0..<3 {
        let centreY = firstRowY - CGFloat(row) * rowSpacing
        let box = CGRect(x: boxX, y: centreY - boxSize / 2, width: boxSize, height: boxSize)

        if row < 2 {
            // Ticked: filled box with a check cut through it.
            let path = NSBezierPath(roundedRect: box, xRadius: boxSize * 0.28, yRadius: boxSize * 0.28)
            path.fill()

            let tick = NSBezierPath()
            tick.lineWidth = lineWidth * 0.9
            tick.lineCapStyle = .round
            tick.lineJoinStyle = .round
            tick.move(to: NSPoint(x: box.minX + boxSize * 0.24, y: box.midY + boxSize * 0.02))
            tick.line(to: NSPoint(x: box.midX - boxSize * 0.02, y: box.minY + boxSize * 0.26))
            tick.line(to: NSPoint(x: box.maxX - boxSize * 0.20, y: box.maxY - boxSize * 0.24))
            NSColor(calibratedRed: 0.27, green: 0.25, blue: 0.68, alpha: 1).setStroke()
            tick.stroke()
            NSColor.white.setStroke()
        } else {
            let path = NSBezierPath(roundedRect: box.insetBy(dx: lineWidth / 2, dy: lineWidth / 2),
                                    xRadius: boxSize * 0.24, yRadius: boxSize * 0.24)
            path.lineWidth = lineWidth
            NSColor.white.withAlphaComponent(0.75).setStroke()
            path.stroke()
        }

        let bar = NSBezierPath(
            roundedRect: CGRect(
                x: barX,
                y: centreY - lineWidth * 0.65,
                width: row == 2 ? barWidth * 0.62 : barWidth,
                height: lineWidth * 1.3
            ),
            xRadius: lineWidth * 0.65,
            yRadius: lineWidth * 0.65
        )
        NSColor.white.withAlphaComponent(row == 2 ? 0.6 : 0.92).setFill()
        bar.fill()
    }

    graphicsContext.flushGraphics()
    return bitmap.representation(using: .png, properties: [:])
}

// The set of sizes iconutil expects.
let variants: [(name: String, size: CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]

for variant in variants {
    guard let data = render(size: variant.size) else {
        FileHandle.standardError.write(Data("failed to render \(variant.name)\n".utf8))
        exit(1)
    }
    try data.write(to: outputDirectory.appendingPathComponent(variant.name))
}

print("wrote \(variants.count) icon variants to \(outputDirectory.path)")
