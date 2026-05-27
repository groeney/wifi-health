// gen-icon.swift — render the wifi-health menu bar icon.
//
// Usage: gen-icon <RRGGBB> <down-level> <up-level>
//   down-level / up-level: "none" (no arrow) or "0".."5"
//
// Level maps to (size, weight) jointly so both axes carry information:
//   0 → 7pt thin           4 → 11pt semibold
//   1 → 8pt light          5 → 12pt bold
//   2 → 9pt regular
//   3 → 10pt medium
//
// Layout: colored dot, then optional ↓, then optional ↑. Canvas width
// sized exactly to what's drawn so we waste no menu bar pixels.
// Outputs a base64-encoded PNG to stdout.

import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write(
        "usage: gen-icon <RRGGBB> <down-level> <up-level>\n".data(using: .utf8)!
    )
    exit(2)
}

let colorHex = args[1].replacingOccurrences(of: "#", with: "")
let downArg  = args[2]
let upArg    = args[3]

// One spec per level. (size, weight) move together — bigger AND bolder
// as bandwidth grows, so the difference between L0 and L5 is striking.
let levelSpecs: [(size: CGFloat, weight: NSFont.Weight)] = [
    ( 7, .thin),       // L0  10–50  KB/s
    ( 8, .light),      // L1  50–500 KB/s
    ( 9, .regular),    // L2  500K–5  MB/s
    (10, .medium),     // L3   5–50  MB/s
    (11, .semibold),   // L4  50–500 MB/s
    (12, .bold),       // L5  500MB+
]

func parseLevel(_ s: String) -> (CGFloat, NSFont.Weight)? {
    if s == "none" { return nil }
    guard let i = Int(s), i >= 0, i < levelSpecs.count else { return nil }
    return levelSpecs[i]
}

let downSpec = parseLevel(downArg)
let upSpec   = parseLevel(upArg)

func hexColor(_ s: String) -> NSColor {
    let v = UInt32(s, radix: 16) ?? 0
    return NSColor(
        red:   CGFloat((v >> 16) & 0xFF) / 255.0,
        green: CGFloat((v >> 8)  & 0xFF) / 255.0,
        blue:  CGFloat( v        & 0xFF) / 255.0,
        alpha: 1.0
    )
}

let dotColor   = hexColor(colorHex)
let arrowColor = NSColor(white: 0.40, alpha: 1.0)

// ── Geometry ────────────────────────────────────────────────────────
let height:   CGFloat = 14
let leftPad:  CGFloat = 1
let dotSize:  CGFloat = 9
let dotEnd:   CGFloat = leftPad + dotSize  // 10
let gap:      CGFloat = 1                   // dot → first arrow
let arrowGap: CGFloat = 1                   // ↓ → ↑
let rightPad: CGFloat = 1

func attrString(_ glyph: String, _ spec: (CGFloat, NSFont.Weight)) -> NSAttributedString {
    NSAttributedString(string: glyph, attributes: [
        .font: NSFont.systemFont(ofSize: spec.0, weight: spec.1),
        .foregroundColor: arrowColor,
    ])
}

let downStr = downSpec.map { attrString("↓", $0) }
let upStr   = upSpec.map   { attrString("↑", $0) }

let downWidth: CGFloat = downStr.map { ceil($0.size().width) } ?? 0
let upWidth:   CGFloat = upStr.map   { ceil($0.size().width) } ?? 0

// Canvas exactly fits what's drawn — no dead pixels on either side.
var width: CGFloat = dotEnd + rightPad
if downSpec != nil && upSpec != nil {
    width = dotEnd + gap + downWidth + arrowGap + upWidth + rightPad
} else if downSpec != nil {
    width = dotEnd + gap + downWidth + rightPad
} else if upSpec != nil {
    width = dotEnd + gap + upWidth + rightPad
}

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

// Arrows in order: ↓ then ↑.
var x = dotEnd + gap
for str in [downStr, upStr].compactMap({ $0 }) {
    let s = str.size()
    let y = (height - s.height) / 2.0 - 0.5
    str.draw(at: NSPoint(x: x, y: y))
    x += ceil(s.width) + arrowGap
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
