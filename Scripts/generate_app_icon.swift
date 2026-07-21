#!/usr/bin/env swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Apple Core app icon generator: renders the menu bar's SF Symbol
// (app.connected.to.app.below.fill) as a white glyph on a rounded-rect
// gradient tile, replacing the inherited iMCP artwork. Run from the repo
// root; writes the PNG sizes App/Assets.xcassets/AppIcon.appiconset's
// Contents.json expects. This is the canonical, reproducible app artwork.
// Structure follows bridgeport's
// script/generate_app_icon.swift.

import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset")

let symbolName = "app.connected.to.app.below.fill"

func drawIcon(size: Int) throws -> Data {
    guard
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size,
            pixelsHigh: size,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
    else {
        throw NSError(domain: "AppleCoreIcon", code: 1)
    }
    bitmap.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let s = CGFloat(size)
    let bounds = NSRect(x: 0, y: 0, width: s, height: s)
    NSColor.clear.setFill()
    bounds.fill()

    // macOS-style rounded tile with the standard ~10% margin.
    let inset = s * 0.098
    let tile = bounds.insetBy(dx: inset, dy: inset)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: s * 0.185, yRadius: s * 0.185)
    let background = NSGradient(colors: [
        NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.19, alpha: 1.0),
        NSColor(calibratedRed: 0.24, green: 0.27, blue: 0.36, alpha: 1.0),
    ])!
    background.draw(in: tilePath, angle: 300)

    // The connector symbol, white, centered.
    let configuration = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .medium)
    guard
        let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    else {
        throw NSError(domain: "AppleCoreIcon", code: 2)
    }
    let tinted = NSImage(size: symbol.size, flipped: false) { rect in
        symbol.draw(in: rect)
        NSColor.white.set()
        rect.fill(using: .sourceAtop)
        return true
    }
    let glyphWidth = tile.width * 0.60
    let aspect = symbol.size.height / symbol.size.width
    let glyphSize = NSSize(width: glyphWidth, height: glyphWidth * aspect)
    let glyphOrigin = NSPoint(
        x: tile.midX - glyphSize.width / 2,
        y: tile.midY - glyphSize.height / 2
    )
    tinted.draw(
        in: NSRect(origin: glyphOrigin, size: glyphSize),
        from: .zero,
        operation: .sourceOver,
        fraction: 1.0
    )

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "AppleCoreIcon", code: 3)
    }
    return png
}

let outputs: [(String, Int)] = [
    ("Icon-macOS-32x32.png", 32),
    ("Icon-macOS-64x64.png", 64),
    ("Icon-macOS-128x128.png", 128),
    ("Icon-macOS-256x256.png", 256),
    ("Icon-macOS-512x512.png", 512),
    ("Icon-macOS-512x512@2x.png", 1024),
]

for (name, size) in outputs {
    let data = try drawIcon(size: size)
    try data.write(to: iconset.appendingPathComponent(name))
    print("wrote \(name) (\(size)x\(size))")
}
