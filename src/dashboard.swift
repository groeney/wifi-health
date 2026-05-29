// dashboard.swift — the "Dashboard" pop-out window for wifi-health.
//
// A small native AppKit + SwiftUI app: live connection metrics plus the
// interactive tests (call quality, speed test) that need real progress
// feedback — things a menu can't do. Buttons work because the app owns
// its own subprocesses (unlike a SwiftBar menu action).
//
// Launched via `open WifiHealth.app` from the pared-down SwiftBar menu.
// Compiled locally by install.sh — no notarization needed.

import AppKit
import SwiftUI
import CoreWLAN
import Foundation

// ── Helpers ─────────────────────────────────────────────────────────
func runCmd(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

func humanRate(_ b: Int) -> String {
    if b < 1024 { return "\(b) B/s" }
    if b < 1_048_576 { return String(format: "%.0f KB/s", Double(b) / 1024) }
    if b < 1_073_741_824 { return String(format: "%.1f MB/s", Double(b) / 1_048_576) }
    return String(format: "%.1f GB/s", Double(b) / 1_073_741_824)
}

extension Color {
    init(hex: String) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let v = UInt64(s, radix: 16) ?? 0
        self = Color(red: Double((v >> 16) & 0xFF) / 255,
                     green: Double((v >> 8) & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255)
    }
}

let GREEN = Color(hex: "4CAF50")
let AMBER = Color(hex: "FF9800")
let RED   = Color(hex: "F44336")

func tagColor(_ tag: String) -> Color {
    switch tag { case "WARN": return AMBER; case "BAD": return RED; case "NA": return .secondary; default: return GREEN }
}

func relative(_ d: Date) -> String {
    let s = Int(Date().timeIntervalSince(d))
    if s < 5 { return "just now" }
    if s < 60 { return "\(s)s ago" }
    if s < 3600 { return "\(s / 60)m ago" }
    return "\(s / 3600)h ago"
}

// ── Model ───────────────────────────────────────────────────────────
final class WifiModel: ObservableObject {
    @Published var ssid = "—"
    @Published var rssi = 0
    @Published var noise = 0
    @Published var snr = 0
    @Published var txRate = 0
    @Published var channel = "—"
    @Published var band = "—"
    @Published var downRate = 0
    @Published var upRate = 0
    @Published var latency: Int? = nil
    @Published var jitter: Int? = nil
    @Published var loss: Int? = nil
    @Published var online = true
    @Published var lastUpdate = Date()

    struct Hop: Identifiable { let id = UUID(); let name: String; let tag: String; let detail: String }
    @Published var diagRunning = false
    @Published var diagHops: [Hop] = []
    @Published var diagVerdict = ""
    @Published var diagCheckedAt: Date? = nil

    @Published var speedRunning = false
    @Published var speedDown: String? = nil
    @Published var speedUp: String? = nil
    @Published var speedResp: String? = nil
    @Published var speedCheckedAt: Date? = nil

    private let iface = CWWiFiClient.shared().interface()
    private var lastIn = 0, lastOut = 0
    private var lastSample = Date()
    private var timer: Timer?
    private let helperDir = NSString(string: "~/Library/Application Support/SwiftBar").expandingTildeInPath
    private var diagScript: String { helperDir + "/diagnose-call.sh" }
    private var resultFile: String { helperDir + "/diagnose.result" }

    func start() {
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in self?.tick() }
    }

    func tick() {
        readWifi(); sampleThroughput(); pingAsync()
        lastUpdate = Date()
    }

    private func readWifi() {
        guard let i = iface else { return }
        ssid = i.ssid() ?? "—"
        rssi = i.rssiValue(); noise = i.noiseMeasurement(); snr = rssi - noise
        txRate = Int(i.transmitRate())
        if let ch = i.wlanChannel() {
            channel = "\(ch.channelNumber)"
            switch ch.channelBand.rawValue { case 1: band = "2.4GHz"; case 2: band = "5GHz"; case 3: band = "6GHz"; default: band = "—" }
        }
    }

    private func sampleThroughput() {
        let out = runCmd("/usr/sbin/netstat", ["-bI", "en0"])
        for line in out.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if f.count >= 10, f[0] == "en0", f[2].contains("Link") {
                let bin = Int(f[6]) ?? 0, bout = Int(f[9]) ?? 0
                let now = Date(); let dt = now.timeIntervalSince(lastSample)
                if lastIn > 0, dt > 0 {
                    downRate = max(0, Int(Double(bin - lastIn) / dt))
                    upRate = max(0, Int(Double(bout - lastOut) / dt))
                }
                lastIn = bin; lastOut = bout; lastSample = now
                break
            }
        }
    }

    private func pingAsync() {
        DispatchQueue.global().async { [weak self] in
            let out = runCmd("/sbin/ping", ["-c", "3", "-i", "0.2", "-W", "1", "1.1.1.1"])
            var on = false, lat: Int? = nil, jit: Int? = nil, los: Int? = nil
            if out.contains("packets transmitted") {
                on = true
                if let m = out.range(of: "([0-9.]+)% packet loss", options: .regularExpression) {
                    los = Int(out[m].split(separator: "%")[0].split(separator: " ").last ?? "0") ?? 0
                }
                if let s = out.range(of: "= [0-9./]+ ms", options: .regularExpression) {
                    let nums = out[s].dropFirst(2).split(separator: " ")[0].split(separator: "/")
                    if nums.count >= 4 { lat = Int(Double(nums[1]) ?? 0); jit = Int(Double(nums[3]) ?? 0) }
                }
            }
            DispatchQueue.main.async { self?.online = on; self?.latency = lat; self?.jitter = jit; self?.loss = los }
        }
    }

    var status: (Color, String, String) {
        if !online { return (RED, "No internet", "Connected to wifi but can't reach the web") }
        let l = loss ?? 0, lt = latency ?? 0, jt = jitter ?? 0
        if l > 10 || lt > 200 { return (RED, "Poor", "High loss or latency — calls and pages will struggle") }
        if l > 2 || lt > 80 || jt > 30 || rssi < -72 { return (AMBER, "OK", "Usable, but room to improve") }
        return (GREEN, "Good", "You're good")
    }

    // ── Call quality ────────────────────────────────────────────────
    func runDiagnosis() {
        guard !diagRunning else { return }
        diagRunning = true; diagHops = []
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            _ = runCmd("/bin/bash", [self.diagScript, "--widget"])
            let parsed = self.parseResult()
            DispatchQueue.main.async {
                self.diagHops = parsed.hops; self.diagVerdict = parsed.verdict
                self.diagCheckedAt = Date(); self.diagRunning = false
            }
        }
    }

    private func parseResult() -> (hops: [Hop], verdict: String) {
        guard let text = try? String(contentsOfFile: resultFile, encoding: .utf8) else { return ([], "") }
        var map: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { map[parts[0]] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        func hop(_ key: String, _ label: String) -> Hop? {
            guard let raw = map[key] else { return nil }
            let f = raw.split(separator: " ").map(String.init)
            guard f.count >= 4 else { return nil }
            if key == "DIAG_BLOAT" { return Hop(name: label, tag: f[0], detail: "+\(f[3])ms under load") }
            return Hop(name: label, tag: f[0], detail: "\(f[1])% loss · \(f[2])ms · ±\(f[3])ms")
        }
        var hops: [Hop] = []
        if let h = hop("DIAG_RTR", "Router (local)") { hops.append(h) }
        if let h = hop("DIAG_CF", "Internet") { hops.append(h) }
        if let h = hop("DIAG_GG", "Google / Meet") { hops.append(h) }
        if let h = hop("DIAG_BLOAT", "Bufferbloat") { hops.append(h) }
        return (hops, map["DIAG_VERDICT"] ?? "")
    }

    // ── Speed test (networkQuality) ─────────────────────────────────
    func runSpeedTest() {
        guard !speedRunning else { return }
        speedRunning = true; speedDown = nil; speedUp = nil; speedResp = nil
        DispatchQueue.global().async { [weak self] in
            let out = runCmd("/usr/bin/networkQuality", [])
            func grab(_ label: String) -> String? {
                for line in out.split(separator: "\n") where line.contains(label) {
                    if let v = line.split(separator: ":").last { return v.trimmingCharacters(in: .whitespaces) }
                }
                return nil
            }
            let down = grab("Downlink capacity"), up = grab("Uplink capacity"), resp = grab("Responsiveness")
            DispatchQueue.main.async {
                self?.speedDown = down; self?.speedUp = up; self?.speedResp = resp
                self?.speedCheckedAt = Date(); self?.speedRunning = false
            }
        }
    }

    func openWifiSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

// ── View ────────────────────────────────────────────────────────────
struct DashboardView: View {
    @EnvironmentObject var model: WifiModel

    var body: some View {
        let (col, label, msg) = model.status
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Circle().fill(col).frame(width: 14, height: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.ssid).font(.system(size: 16, weight: .semibold))
                    Text("\(label) — \(msg)").font(.system(size: 11)).foregroundColor(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 4) {
                        Circle().fill(GREEN).frame(width: 6, height: 6)
                        Text("live").font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    Text("updated \(relative(model.lastUpdate))").font(.system(size: 9)).foregroundColor(.secondary)
                }
            }
            .padding(16)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Live metrics
                    section("LIVE") {
                        row { metric("↓ Down", humanRate(model.downRate)); metric("↑ Up", humanRate(model.upRate)) }
                        row { metric("Latency", model.latency.map { "\($0) ms (±\(model.jitter ?? 0))" } ?? "—"); metric("Loss", model.loss.map { "\($0)%" } ?? "—") }
                        row { metric("Signal", "\(model.rssi) dBm"); metric("SNR", "\(model.snr) dB") }
                        row { metric("Channel", "\(model.channel) (\(model.band))"); metric("Link", "\(model.txRate) Mbps") }
                    }
                    Divider()

                    // Call quality
                    section("CALL QUALITY", trailing: model.diagCheckedAt.map { relative($0) }) {
                        if model.diagRunning {
                            busy("Testing your path… (~15s)")
                        } else if !model.diagHops.isEmpty {
                            ForEach(model.diagHops) { h in
                                HStack(spacing: 10) {
                                    Text(h.tag).font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundColor(tagColor(h.tag)).frame(width: 40, alignment: .leading)
                                    Text(h.name).font(.system(size: 12)).frame(width: 110, alignment: .leading)
                                    Text(h.detail).font(.system(size: 12, design: .monospaced)).foregroundColor(.secondary)
                                    Spacer()
                                }
                            }
                            verdictBox(model.diagVerdict)
                        } else {
                            Text("Choppy call? Find out if it's you or the other end.").font(.system(size: 12)).foregroundColor(.secondary)
                        }
                        Button(action: { model.runDiagnosis() }) {
                            Text(model.diagHops.isEmpty ? "Run call-quality check" : "Run again").frame(maxWidth: .infinity)
                        }.controlSize(.large).disabled(model.diagRunning)
                    }
                    Divider()

                    // Speed test
                    section("SPEED TEST", trailing: model.speedCheckedAt.map { relative($0) }) {
                        if model.speedRunning {
                            busy("Measuring throughput… (~15s)")
                        } else if model.speedDown != nil || model.speedUp != nil {
                            row { metric("↓ Download", model.speedDown ?? "—"); metric("↑ Upload", model.speedUp ?? "—") }
                            if let r = model.speedResp { metric("Responsiveness", r).padding(.top, 2) }
                        } else {
                            Text("Measure real download/upload throughput.").font(.system(size: 12)).foregroundColor(.secondary)
                        }
                        Button(action: { model.runSpeedTest() }) {
                            Text(model.speedDown == nil ? "Run speed test" : "Run again").frame(maxWidth: .infinity)
                        }.controlSize(.large).disabled(model.speedRunning)
                    }
                }
            }

            Divider()
            HStack {
                Button("Refresh") { model.tick() }
                Spacer()
                Button("Wi-Fi settings…") { model.openWifiSettings() }
            }
            .controlSize(.small)
            .padding(12)
        }
        .frame(width: 460, height: 680, alignment: .topLeading)
    }

    func section<C: View>(_ title: String, trailing: String? = nil, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 10, weight: .bold)).foregroundColor(.secondary)
                Spacer()
                if let t = trailing { Text(t).font(.system(size: 10)).foregroundColor(.secondary) }
            }
            content()
        }
        .padding(16)
    }

    func row<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 24) { content() }
    }

    func metric(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k).font(.system(size: 10)).foregroundColor(.secondary)
            Text(v).font(.system(size: 13, design: .monospaced))
        }
        .frame(width: 180, alignment: .leading)
    }

    func busy(_ t: String) -> some View {
        HStack(spacing: 8) { ProgressView().scaleEffect(0.6); Text(t).font(.system(size: 12)).foregroundColor(.secondary) }
    }

    @ViewBuilder func verdictBox(_ v: String) -> some View {
        let (c, t): (Color, String) = {
            switch v {
            case "local":  return (RED, "Likely YOU — your wifi/local link. Move closer, try 5GHz, or reconnect.")
            case "bloat":  return (RED, "Bufferbloat — something is saturating your link. Pause big downloads/uploads.")
            case "remote": return (AMBER, "Your ISP / upstream path is degraded. Local link is clean.")
            default:        return (GREEN, "Your side is clean — most likely the other participant or the call server.")
            }
        }()
        Text(t).font(.system(size: 12)).padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(c.opacity(0.15)).cornerRadius(8)
    }
}

// ── App bootstrap ───────────────────────────────────────────────────
class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let model = WifiModel()
    func applicationDidFinishLaunching(_ note: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 680),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "WiFi Health"
        window.center()
        window.contentView = NSHostingView(rootView: DashboardView().environmentObject(model))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.start()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
