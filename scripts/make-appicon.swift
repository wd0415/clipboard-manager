#!/usr/bin/env swift
import AppKit

// Draws Resources/AppIcon.icns from code, so the icon has a source that can be edited rather than
// a binary nobody can change. Run from the repository root:
//
//     swift scripts/make-appicon.swift
//
// The clipboard is drawn from Bézier paths instead of being taken from SF Symbols: Apple's SF
// Symbols licence excludes app icons and logos.
//
// Geometry is written in a 1024pt square and scaled per size, so every size in the iconset is
// rasterised from the same shapes rather than resampled from one bitmap.

let canvas: CGFloat = 1024
/// Inset of the rounded body. macOS icons are a rounded square inset inside the full canvas, not
/// a rounded canvas; the margin is what keeps the shape from touching the Dock's own edges.
let bodyInset: CGFloat = 100
/// Big Sur's corner radius as a fraction of the body's side.
let cornerRadius: CGFloat = (canvas - bodyInset * 2) * 0.2237

let gradientTop = NSColor(srgbRed: 0.24, green: 0.52, blue: 0.98, alpha: 1)
let gradientBottom = NSColor(srgbRed: 0.33, green: 0.28, blue: 0.82, alpha: 1)
let lineColor = NSColor(srgbRed: 0.29, green: 0.40, blue: 0.90, alpha: 1)

func drawIcon() {
    let body = NSRect(x: bodyInset, y: bodyInset, width: canvas - bodyInset * 2, height: canvas - bodyInset * 2)
    let shape = NSBezierPath(roundedRect: body, xRadius: cornerRadius, yRadius: cornerRadius)
    NSGradient(starting: gradientTop, ending: gradientBottom)?.draw(in: shape, angle: -90)

    NSColor.white.setFill()
    let board = NSRect(x: 268, y: 212, width: 488, height: 552)
    NSBezierPath(roundedRect: board, xRadius: 60, yRadius: 60).fill()
    // The clip straddles the board's top edge; both are white, so the two read as one shape.
    let clip = NSRect(x: 412, y: 720, width: 200, height: 92)
    NSBezierPath(roundedRect: clip, xRadius: 44, yRadius: 44).fill()

    lineColor.setFill()
    for y in [330.0, 450.0, 570.0] {
        NSBezierPath(
            roundedRect: NSRect(x: 348, y: y, width: 328, height: 56),
            xRadius: 28,
            yRadius: 28
        ).fill()
    }
}

func render(pixels: Int) -> NSBitmapImageRep? {
    guard let rep = NSBitmapImageRep(
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
    ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let scale = CGFloat(pixels) / canvas
    context.cgContext.scaleBy(x: scale, y: scale)
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// The ten entries `iconutil` expects, as (point size, scale).
let variants: [(point: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for variant in variants {
    let pixels = variant.point * variant.scale
    guard let rep = render(pixels: pixels),
          let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("failed to render \(pixels)px\n".data(using: .utf8)!)
        exit(1)
    }
    let suffix = variant.scale == 1 ? "" : "@\(variant.scale)x"
    let name = "icon_\(variant.point)x\(variant.point)\(suffix).png"
    try data.write(to: iconset.appendingPathComponent(name))
}

let output = root.appendingPathComponent("Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed\n".data(using: .utf8)!)
    exit(1)
}
print("wrote \(output.path)")
