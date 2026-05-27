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
// Darker gray — 55% was too faint to see clearly at menu bar scale.
let arrowColor = NSColor(white: 0.40, alpha: 1.0)

// ── Geometry ────────────────────────────────────────────────────────
// Idle: nothing but the dot, in a canvas just wide enough to contain
// it. Active: dot + a small arrow tucked flush against it. Width grows
// only as much as the glyph needs so we waste no menu bar pixels.
let height:     CGFloat = 14
let leftPad:    CGFloat = 1
let dotSize:    CGFloat = 9
let dotEnd:     CGFloat = leftPad + dotSize    // 10
let gap:        CGFloat = 1
let rightPad:   CGFloat = 1

// Pick the arrow glyph. ↕ (U+2195) is a single character for "both"
// directions — narrower and clearer at small sizes than ⇅.
let glyph: String? = {
    switch activity {
    case "down": return "↓"
    case "up":   return "↑"
    case "both": return "↕"
    default:     return nil
    }
}()

// 9pt — a bit smaller than the original 10pt but readable at menu bar
// scale (8pt disappeared into the background gray).
let arrowFont = NSFont.systemFont(ofSize: 9, weight: .medium)
let arrowAttrs: [NSAttributedString.Key: Any] = [
    .font: arrowFont,
    .foregroundColor: arrowColor,
]

// Measure the glyph so the canvas width can be exact.
var arrowWidth: CGFloat = 0
var arrowStr: NSAttributedString? = nil
if let g = glyph {
    let s = NSAttributedString(string: g, attributes: arrowAttrs)
    arrowStr  = s
    arrowWidth = ceil(s.size().width)
}

let width: CGFloat = glyph == nil
    ? dotEnd + rightPad                       // idle: 11pt
    : dotEnd + gap + arrowWidth + rightPad    // active: tight to glyph

let image = NSImage(size: NSSize(width: width, height: height))
image.lockFocus()

if let ctx = NSGraphicsContext.current {
    ctx.shouldAntialias  = true
    ctx.imageInterpolation = .high
}

// Dot on the left, vertically centered.
let dotRect = NSRect(
    x: leftPad,
    y: (height - dotSize) / 2.0,
    width: dotSize,
    height: dotSize
)
dotColor.setFill()
NSBezierPath(ovalIn: dotRect).fill()

// Arrow tucked against the dot, vertically centered.
if let arrow = arrowStr {
    let s = arrow.size()
    let x = dotEnd + gap
    let y = (height - s.height) / 2.0 - 0.5
    arrow.draw(at: NSPoint(x: x, y: y))
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
