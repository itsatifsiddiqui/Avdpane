// Draws the app icon as a 1024x1024 PNG. Run: swift Resources/make-icon.swift
// Output goes next to this script as AppIcon.png.
import AppKit

let size: CGFloat = 1024
let outputPath = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    .appendingPathComponent("AppIcon.png").path

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
    // Dark slate rounded square, same corner radius macOS uses for its own icons.
    NSColor(red: 0.17, green: 0.20, blue: 0.25, alpha: 1).setFill()
    NSBezierPath(roundedRect: rect, xRadius: 225, yRadius: 225).fill()

    // Phone body: white outline, centered.
    let body = NSRect(x: 322, y: 172, width: 380, height: 680)
    let outline = NSBezierPath(roundedRect: body, xRadius: 56, yRadius: 56)
    outline.lineWidth = 28
    NSColor.white.setStroke()
    outline.stroke()

    // Screen: Android green, inset from the body.
    NSColor(red: 0x3D / 255, green: 0xDC / 255, blue: 0x84 / 255, alpha: 1).setFill()
    NSBezierPath(roundedRect: body.insetBy(dx: 44, dy: 84), xRadius: 20, yRadius: 20).fill()

    // Speaker slot at the top and home dot at the bottom.
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: 462, y: 800, width: 100, height: 16), xRadius: 8, yRadius: 8).fill()
    NSBezierPath(ovalIn: NSRect(x: 494, y: 200, width: 36, height: 36)).fill()
    return true
}

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("could not render icon")
}
try png.write(to: URL(fileURLWithPath: outputPath))
print(outputPath)
