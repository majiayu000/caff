#!/usr/bin/env swift

import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: render_app_icon.swift <resources-dir>\n".utf8))
    exit(64)
}

let resourcesURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconsetURL = resourcesURL.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let fileManager = FileManager.default

try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let iconSpecs: [(name: String, size: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for spec in iconSpecs {
    let data = renderAppIcon(size: spec.size)
    try data.write(to: iconsetURL.appendingPathComponent(spec.name))
}

print(iconsetURL.path)

private func renderAppIcon(size: Int) -> Data {
    renderPNG(size: size) { rect in
        drawIcon(in: rect)
    }
}

private func renderPNG(size: Int, draw: (CGRect) -> Void) -> Data {
    guard let rep = NSBitmapImageRep(
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
    ) else {
        fatalError("could not create bitmap")
    }

    rep.size = NSSize(width: size, height: size)

    guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("could not create graphics context")
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.clear(CGRect(x: 0, y: 0, width: size, height: size))
    context.cgContext.setShouldAntialias(true)
    draw(CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size)))
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode png")
    }

    return data
}

private func drawIcon(in rect: CGRect) {
    let side = min(rect.width, rect.height)
    let frame = CGRect(
        x: rect.midX - side / 2,
        y: rect.midY - side / 2,
        width: side,
        height: side
    )
    let unit = side / 1024

    let background = frame.insetBy(dx: 72 * unit, dy: 72 * unit)
    let backgroundPath = NSBezierPath(
        roundedRect: background,
        xRadius: 210 * unit,
        yRadius: 210 * unit
    )

    let backgroundShadow = NSShadow()
    backgroundShadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
    backgroundShadow.shadowBlurRadius = 30 * unit
    backgroundShadow.shadowOffset = NSSize(width: 0, height: -18 * unit)

    NSGraphicsContext.saveGraphicsState()
    backgroundShadow.set()
    NSGradient(colors: [
        color(hex: 0x10201F),
        color(hex: 0x1A2E2B),
        color(hex: 0x34251D),
    ])?.draw(in: backgroundPath, angle: -35)
    NSGraphicsContext.restoreGraphicsState()

    let innerGlow = NSBezierPath(
        roundedRect: background.insetBy(dx: 34 * unit, dy: 34 * unit),
        xRadius: 172 * unit,
        yRadius: 172 * unit
    )
    color(hex: 0x7DE2C3, alpha: 0.08).setStroke()
    innerGlow.lineWidth = 10 * unit
    innerGlow.stroke()

    drawSteam(in: frame, unit: unit)
    drawCup(in: frame, unit: unit)
}

private func drawSteam(in frame: CGRect, unit: CGFloat) {
    let amber = color(hex: 0xF3A946)
    let mint = color(hex: 0x7DE2C3)

    stroke(points: [
        CGPoint(x: frame.minX + 386 * unit, y: frame.minY + 684 * unit),
        CGPoint(x: frame.minX + 350 * unit, y: frame.minY + 740 * unit),
        CGPoint(x: frame.minX + 396 * unit, y: frame.minY + 812 * unit),
    ], width: 28 * unit, color: amber.withAlphaComponent(0.88))

    stroke(points: [
        CGPoint(x: frame.minX + 512 * unit, y: frame.minY + 690 * unit),
        CGPoint(x: frame.minX + 472 * unit, y: frame.minY + 748 * unit),
        CGPoint(x: frame.minX + 528 * unit, y: frame.minY + 814 * unit),
        CGPoint(x: frame.minX + 492 * unit, y: frame.minY + 870 * unit),
    ], width: 30 * unit, color: mint.withAlphaComponent(0.95))

    stroke(points: [
        CGPoint(x: frame.minX + 636 * unit, y: frame.minY + 682 * unit),
        CGPoint(x: frame.minX + 684 * unit, y: frame.minY + 742 * unit),
        CGPoint(x: frame.minX + 634 * unit, y: frame.minY + 806 * unit),
    ], width: 28 * unit, color: amber.withAlphaComponent(0.80))
}

private func drawCup(in frame: CGRect, unit: CGFloat) {
    let cupRect = CGRect(
        x: frame.minX + 268 * unit,
        y: frame.minY + 304 * unit,
        width: 438 * unit,
        height: 318 * unit
    )
    let saucerRect = CGRect(
        x: frame.minX + 224 * unit,
        y: frame.minY + 248 * unit,
        width: 594 * unit,
        height: 64 * unit
    )

    let cupShadow = NSShadow()
    cupShadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    cupShadow.shadowBlurRadius = 22 * unit
    cupShadow.shadowOffset = NSSize(width: 0, height: -12 * unit)

    NSGraphicsContext.saveGraphicsState()
    cupShadow.set()
    let saucer = NSBezierPath(
        roundedRect: saucerRect,
        xRadius: 32 * unit,
        yRadius: 32 * unit
    )
    color(hex: 0xF1E7D2, alpha: 0.92).setFill()
    saucer.fill()
    NSGraphicsContext.restoreGraphicsState()

    let cup = NSBezierPath(
        roundedRect: cupRect,
        xRadius: 66 * unit,
        yRadius: 66 * unit
    )
    NSGradient(colors: [
        color(hex: 0xFFF7E6),
        color(hex: 0xE9D7B9),
    ])?.draw(in: cup, angle: -90)

    let coffee = NSBezierPath(ovalIn: CGRect(
        x: cupRect.minX + 44 * unit,
        y: cupRect.maxY - 74 * unit,
        width: cupRect.width - 88 * unit,
        height: 74 * unit
    ))
    color(hex: 0x5D3823).setFill()
    coffee.fill()

    let coffeeHighlight = NSBezierPath(ovalIn: CGRect(
        x: cupRect.minX + 96 * unit,
        y: cupRect.maxY - 54 * unit,
        width: 114 * unit,
        height: 24 * unit
    ))
    color(hex: 0xF3A946, alpha: 0.52).setFill()
    coffeeHighlight.fill()

    let handleRect = CGRect(
        x: cupRect.maxX - 26 * unit,
        y: cupRect.minY + 88 * unit,
        width: 170 * unit,
        height: 160 * unit
    )
    let handle = NSBezierPath(
        roundedRect: handleRect,
        xRadius: 84 * unit,
        yRadius: 84 * unit
    )
    color(hex: 0xF4E6CE).setStroke()
    handle.lineWidth = 42 * unit
    handle.stroke()

    let terminalRect = CGRect(
        x: cupRect.minX + 102 * unit,
        y: cupRect.minY + 92 * unit,
        width: 226 * unit,
        height: 126 * unit
    )
    let terminal = NSBezierPath(
        roundedRect: terminalRect,
        xRadius: 26 * unit,
        yRadius: 26 * unit
    )
    color(hex: 0x10201F).setFill()
    terminal.fill()

    let prompt = NSBezierPath()
    prompt.move(to: CGPoint(x: terminalRect.minX + 44 * unit, y: terminalRect.minY + 86 * unit))
    prompt.line(to: CGPoint(x: terminalRect.minX + 84 * unit, y: terminalRect.minY + 63 * unit))
    prompt.line(to: CGPoint(x: terminalRect.minX + 44 * unit, y: terminalRect.minY + 40 * unit))
    prompt.lineCapStyle = .round
    prompt.lineJoinStyle = .round
    prompt.lineWidth = 18 * unit
    color(hex: 0x7DE2C3).setStroke()
    prompt.stroke()

    let cursor = NSBezierPath(
        roundedRect: CGRect(
            x: terminalRect.minX + 116 * unit,
            y: terminalRect.minY + 42 * unit,
            width: 54 * unit,
            height: 18 * unit
        ),
        xRadius: 9 * unit,
        yRadius: 9 * unit
    )
    color(hex: 0xF3A946).setFill()
    cursor.fill()
}

private func stroke(points: [CGPoint], width: CGFloat, color: NSColor) {
    guard let first = points.first else {
        return
    }

    let path = NSBezierPath()
    path.move(to: first)
    for point in points.dropFirst() {
        path.line(to: point)
    }
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.lineWidth = width
    color.setStroke()
    path.stroke()
}

private func color(hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    let red = CGFloat((hex >> 16) & 0xff) / 255
    let green = CGFloat((hex >> 8) & 0xff) / 255
    let blue = CGFloat(hex & 0xff) / 255
    return NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
}
