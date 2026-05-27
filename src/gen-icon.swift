// gen-icon.swift — render the wifi-health menu bar icon.
//
// Usage: gen-icon <RRGGBB> <none|down|up|both>
// Outputs a base64-encoded PNG to stdout.
//
// Layout: a small colored dot on the left, optional gray arrow tucked
// in close to its right. Single image so the two glyphs stay flush
// regardless of macOS menu bar inter-item spacing.

import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: gen-icon <RRGGBB> <none|down|up|both>\n".data(using: .utf8)!)
    exit(2)
}

let colorHex = args[1].replacingOccurrences(of: "#", with: "")
let activity = args[2]

func hexColor(_ s: String) -> NSColor {
    let v = UInt32(s, radix: 16) ?? 0
    let r = CGFloat((v >> 16) & 0xFF) / 255.0
    let g = CGFloat((v >> 8)  & 0xFF) / 255.0
    let b = CGFloat( v        & 0xFF) / 255.0
    return NSColor(red: r, green: g, blue: b, alpha: 1.0)
}

let dotColor   = hexColor(colorHex)
let arrowColor = NSColor(white: 0.55, alpha: 1.0)

// Canvas. Compact width when idle (just the dot); a bit wider when an
// arrow is being drawn. macOS scales these "point" dimensions for
// Retina automatically because we use NSImage with point-sized canvas.
let width:  CGFloat = activity == "none" ? 13 : 20
let height: CGFloat = 14

let image = NSImage(size: NSSize(width: width, height: height))
image.lockFocus()

if let ctx = NSGraphicsContext.current {
    ctx.shouldAntialias  = true
    ctx.imageInterpolation = .high
}

// Dot on the left — 9pt diameter, vertically centered.
let dotSize: CGFloat = 9.0
let dotRect = NSRect(
    x: 1.0,
    y: (height - dotSize) / 2.0,
    width: dotSize,
    height: dotSize
)
dotColor.setFill()
NSBezierPath(ovalIn: dotRect).fill()

// Arrow on the right, drawn as text so we get clean glyph rendering.
if activity != "none" {
    let glyph: String = {
        switch activity {
        case "down": return "↓"
        case "up":   return "↑"
        case "both": return "⇅"
        default:     return ""
        }
    }()
    let font = NSFont.systemFont(ofSize: 10)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: arrowColor,
    ]
    let attrStr = NSAttributedString(string: glyph, attributes: attrs)
    let size = attrStr.size()
    let x: CGFloat = 11.0   // just after the dot, tucked in tight
    let y = (height - size.height) / 2.0 - 0.5
    attrStr.draw(at: NSPoint(x: x, y: y))
}

image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let rep  = NSBitmapImageRep(data: tiff),
    let png  = rep.representation(using: .png, properties: [:])
else {
    FileHandle.standardError.write("failed to render PNG\n".data(using: .utf8)!)
    exit(1)
}

print(png.base64EncodedString())
