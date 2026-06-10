// gen-chart.swift — render the 24h latency sparkline embedded in the
// SwiftBar menu.
//
// Usage: gen-chart <history.csv> <dark|light>
//
// Reads the rolling history log (one CSV row per plugin cycle:
// epoch,status,online,lat,jit,loss,rssi,noise,tx,down,up), buckets the
// last 24h into 1pt columns and draws:
//   • the latency line (gaps where the network was down or wifi off)
//   • a 4pt status strip along the bottom — green/amber/red mirror the
//     menu bar dot, gray = wifi off, faint = no data (laptop asleep)
// Outputs a base64-encoded PNG to stdout; exits 1 when there isn't
// enough data yet (the menu just omits the chart row).

import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: gen-chart <history.csv> <dark|light>\n".data(using: .utf8)!)
    exit(2)
}
let dark = args[2].lowercased() == "dark"

guard let text = try? String(contentsOfFile: args[1], encoding: .utf8) else { exit(1) }

let now = Date().timeIntervalSince1970
let windowStart = now - 86400

struct Row { let t: Double; let status: String; let lat: Double? }
var rows: [Row] = []
for line in text.split(separator: "\n") {
    let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    guard f.count >= 11, let t = Double(f[0]), t >= windowStart, t <= now else { continue }
    rows.append(Row(t: t, status: f[1], lat: Double(f[3])))
}
guard rows.count >= 10 else { exit(1) }

// ── Bucket into 1pt columns ─────────────────────────────────────────
let W: CGFloat = 250, H: CGFloat = 46
let stripH: CGFloat = 4, stripGap: CGFloat = 3, topPad: CGFloat = 4
let n = Int(W)

var latSum = [Double](repeating: 0, count: n)
var latN   = [Int](repeating: 0, count: n)
var pri    = [Int](repeating: 0, count: n)     // worst status: 3=red 2=amber 1=green
var sawOff = [Bool](repeating: false, count: n)

for r in rows {
    let i = min(n - 1, max(0, Int((r.t - windowStart) / 86400 * Double(n))))
    if let l = r.lat { latSum[i] += l; latN[i] += 1 }
    switch r.status {
    case "r": pri[i] = max(pri[i], 3)
    case "y": pri[i] = max(pri[i], 2)
    case "g": pri[i] = max(pri[i], 1)
    default:  sawOff[i] = true
    }
}
let avgs: [Double?] = (0..<n).map { latN[$0] > 0 ? latSum[$0] / Double(latN[$0]) : nil }

// Y scale: a high percentile (not the max) so one spike doesn't squash
// the whole line, snapped up to a round number. Spikes above the cap
// clamp to the top edge.
let sorted = avgs.compactMap { $0 }.sorted()
guard !sorted.isEmpty else { exit(1) }
let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
let niceCaps: [Double] = [50, 75, 100, 150, 200, 300, 500, 750, 1000, 1500, 2000]
let yMax = niceCaps.first(where: { $0 >= p95 * 1.25 }) ?? 2000

// ── Colors ──────────────────────────────────────────────────────────
func hexColor(_ v: UInt32) -> NSColor {
    NSColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}
let cGreen = hexColor(0x4CAF50), cAmber = hexColor(0xFF9800), cRed = hexColor(0xF44336)
let cOff   = NSColor(white: dark ? 0.45 : 0.65, alpha: 1)
let cEmpty = NSColor(white: dark ? 1.0 : 0.0, alpha: 0.07)
let cLine  = NSColor(white: dark ? 0.93 : 0.15, alpha: 1)
let cFill  = NSColor(white: dark ? 0.93 : 0.15, alpha: 0.12)
let cText  = NSColor(white: 0.55, alpha: 1)

// ── Draw ────────────────────────────────────────────────────────────
let image = NSImage(size: NSSize(width: W, height: H))
image.lockFocus()
if let ctx = NSGraphicsContext.current { ctx.shouldAntialias = true }

let chartY0 = stripH + stripGap
let chartH  = H - chartY0 - topPad
func yFor(_ v: Double) -> CGFloat { chartY0 + CGFloat(min(v, yMax) / yMax) * chartH }

// Status strip.
for i in 0..<n {
    let c: NSColor
    switch pri[i] {
    case 3:  c = cRed
    case 2:  c = cAmber
    case 1:  c = cGreen
    default: c = sawOff[i] ? cOff : cEmpty
    }
    c.setFill()
    NSRect(x: CGFloat(i), y: 0, width: 1.0, height: stripH).fill()
}

// Latency line + soft fill, segment by segment (gaps = no data).
var seg: [(x: CGFloat, y: CGFloat)] = []
func flush() {
    defer { seg = [] }
    guard !seg.isEmpty else { return }
    if seg.count == 1 {
        // Lone sample — draw a dot so it isn't invisible.
        cLine.setFill()
        NSBezierPath(ovalIn: NSRect(x: seg[0].x - 1, y: seg[0].y - 1, width: 2, height: 2)).fill()
        return
    }
    let line = NSBezierPath()
    line.lineWidth = 1.2
    line.move(to: NSPoint(x: seg[0].x, y: seg[0].y))
    for p in seg.dropFirst() { line.line(to: NSPoint(x: p.x, y: p.y)) }
    let area = line.copy() as! NSBezierPath
    area.line(to: NSPoint(x: seg.last!.x, y: chartY0))
    area.line(to: NSPoint(x: seg[0].x, y: chartY0))
    area.close()
    cFill.setFill(); area.fill()
    cLine.setStroke(); line.stroke()
}
for i in 0..<n {
    if let v = avgs[i] { seg.append((CGFloat(i) + 0.5, yFor(v))) } else { flush() }
}
flush()

// Y-scale hint, top-left.
let label = NSAttributedString(string: "\(Int(yMax)) ms", attributes: [
    .font: NSFont.systemFont(ofSize: 7, weight: .medium),
    .foregroundColor: cText,
])
label.draw(at: NSPoint(x: 2, y: H - 9))

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
