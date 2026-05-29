// dashboard.swift — the "Dashboard" pop-out window for wifi-health.
//
// Native AppKit + SwiftUI. Live connection metrics plus the interactive
// tests (call quality, speed test) that need real progress feedback —
// things a menu can't do. Buttons work because the app owns its own
// subprocesses. Also self-checks for updates and can apply them.
//
// Launched via `open WifiHealth.app` from the SwiftBar menu. Compiled
// locally by install.sh — no notarization needed.

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

let GREEN  = Color(hex: "30D158")
let AMBER  = Color(hex: "FF9F0A")
let RED    = Color(hex: "FF453A")
let ACCENT = Color(hex: "0A84FF")

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

    @Published var updateState = ""        // available / current / unknown
    @Published var updateApplying = false

    private let iface = CWWiFiClient.shared().interface()
    private var lastIn = 0, lastOut = 0
    private var lastSample = Date()
    private var timer: Timer?
    private let helperDir = NSString(string: "~/Library/Application Support/SwiftBar").expandingTildeInPath
    private var diagScript: String { helperDir + "/diagnose-call.sh" }
    private var resultFile: String { helperDir + "/diagnose.result" }
    private var updateScript: String { helperDir + "/wifi-update.sh" }

    func start() {
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in self?.tick() }
        checkUpdate()
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
        if !online { return (RED, "No internet", "connected to wifi but can't reach the web") }
        let l = loss ?? 0, lt = latency ?? 0, jt = jitter ?? 0
        if l > 10 || lt > 200 { return (RED, "Poor", "high loss or latency — calls will struggle") }
        if l > 2 || lt > 80 || jt > 30 || rssi < -72 { return (AMBER, "OK", "usable, but room to improve") }
        return (GREEN, "Good", "everything looks healthy")
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
            if key == "DIAG_BLOAT" { return Hop(name: label, tag: f[0], detail: "+\(f[3]) ms under load") }
            return Hop(name: label, tag: f[0], detail: "\(f[1])% · \(f[2]) ms · ±\(f[3])")
        }
        var hops: [Hop] = []
        if let h = hop("DIAG_RTR", "Your router") { hops.append(h) }
        if let h = hop("DIAG_CF", "Internet") { hops.append(h) }
        if let h = hop("DIAG_GG", "Google / Meet") { hops.append(h) }
        if let h = hop("DIAG_BLOAT", "Bufferbloat") { hops.append(h) }
        return (hops, map["DIAG_VERDICT"] ?? "")
    }

    // ── Speed test ──────────────────────────────────────────────────
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

    // ── Updates ─────────────────────────────────────────────────────
    func checkUpdate() {
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            let out = runCmd("/bin/bash", [self.updateScript, "check"]).trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async { self.updateState = out }
        }
    }

    func applyUpdate() {
        guard !updateApplying else { return }
        updateApplying = true
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            _ = runCmd("/bin/bash", [self.updateScript, "apply"])
            let appPath = self.helperDir + "/WifiHealth.app"
            DispatchQueue.main.async {
                _ = runCmd("/usr/bin/open", ["-n", appPath])   // launch the rebuilt app
                NSApp.terminate(nil)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if model.updateState == "available" { updateBanner }
                header(col, label, msg)
                metricsCard
                callQualityCard
                speedCard
                footer
            }
            .padding(.horizontal, 18)
            .padding(.top, 34)     // clear the transparent title bar
            .padding(.bottom, 18)
        }
        .frame(width: 430, height: 660)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // Header --------------------------------------------------------
    func header(_ col: Color, _ label: String, _ msg: String) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(col.opacity(0.18)).frame(width: 48, height: 48)
                Circle().fill(col).frame(width: 16, height: 16)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(model.ssid).font(.system(size: 21, weight: .bold))
                (Text(label).foregroundColor(col).fontWeight(.semibold)
                 + Text("  ·  \(msg)").foregroundColor(.secondary))
                    .font(.system(size: 12))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 5) {
                    Circle().fill(GREEN).frame(width: 6, height: 6)
                    Text("LIVE").font(.system(size: 9, weight: .heavy)).tracking(0.8).foregroundColor(.secondary)
                }
                Text(relative(model.lastUpdate)).font(.system(size: 10)).foregroundColor(.secondary)
            }
        }
    }

    // Metrics -------------------------------------------------------
    var metricsCard: some View {
        card {
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                GridItem(.flexible(), alignment: .leading)], spacing: 16) {
                stat("DOWNLOAD", humanRate(model.downRate))
                stat("UPLOAD", humanRate(model.upRate))
                stat("LATENCY", model.latency.map { "\($0) ms" + (model.jitter.map { " ±\($0)" } ?? "") } ?? "—")
                stat("LOSS", model.loss.map { "\($0)%" } ?? "—")
                stat("SIGNAL", "\(model.rssi) dBm")
                stat("SNR", "\(model.snr) dB")
                stat("CHANNEL", "\(model.channel) · \(model.band)")
                stat("LINK RATE", "\(model.txRate) Mbps")
            }
        }
    }

    // Call quality --------------------------------------------------
    var callQualityCard: some View {
        card {
            cardHeader("Call quality", trailing: model.diagCheckedAt.map { relative($0) })
            if model.diagRunning {
                busy("Testing your path…  ~15s")
            } else if !model.diagHops.isEmpty {
                VStack(spacing: 8) { ForEach(model.diagHops) { hopRow($0) } }
                verdictBox(model.diagVerdict)
            } else {
                Text("Choppy call? Find out if it's you or the other end.")
                    .font(.system(size: 12)).foregroundColor(.secondary)
            }
            primaryButton(model.diagHops.isEmpty ? "Run call-quality check" : "Run again",
                          running: model.diagRunning) { model.runDiagnosis() }
        }
    }

    func hopRow(_ h: WifiModel.Hop) -> some View {
        HStack(spacing: 10) {
            Text(h.tag)
                .font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(tagColor(h.tag).opacity(0.18)).foregroundColor(tagColor(h.tag))
                .clipShape(Capsule())
                .frame(width: 52, alignment: .leading)
            Text(h.name).font(.system(size: 13)).frame(width: 110, alignment: .leading)
            Spacer()
            Text(h.detail).font(.system(size: 12, design: .rounded)).foregroundColor(.secondary)
        }
    }

    // Speed test ----------------------------------------------------
    var speedCard: some View {
        card {
            cardHeader("Speed test", trailing: model.speedCheckedAt.map { relative($0) })
            if model.speedRunning {
                busy("Measuring throughput…  ~15s")
            } else if model.speedDown != nil || model.speedUp != nil {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                    GridItem(.flexible(), alignment: .leading)], spacing: 14) {
                    stat("DOWNLOAD", model.speedDown ?? "—")
                    stat("UPLOAD", model.speedUp ?? "—")
                }
                if let r = model.speedResp { stat("RESPONSIVENESS", r) }
            } else {
                Text("Measure real download / upload throughput.")
                    .font(.system(size: 12)).foregroundColor(.secondary)
            }
            primaryButton(model.speedDown == nil ? "Run speed test" : "Run again",
                          running: model.speedRunning) { model.runSpeedTest() }
        }
    }

    // Footer --------------------------------------------------------
    var footer: some View {
        HStack {
            Button { model.tick() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            Spacer()
            Button { model.openWifiSettings() } label: { Label("Wi-Fi settings", systemImage: "gearshape") }
        }
        .buttonStyle(.borderless).controlSize(.small).foregroundColor(.secondary)
        .padding(.top, 2)
    }

    var updateBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill").foregroundColor(ACCENT)
            VStack(alignment: .leading, spacing: 1) {
                Text("Update available").font(.system(size: 12, weight: .semibold))
                Text("a newer version is on GitHub").font(.system(size: 10)).foregroundColor(.secondary)
            }
            Spacer()
            Button(model.updateApplying ? "Updating…" : "Update now") { model.applyUpdate() }
                .buttonStyle(.borderedProminent).tint(ACCENT).controlSize(.small)
                .disabled(model.updateApplying)
        }
        .padding(12)
        .background(ACCENT.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    // Building blocks ----------------------------------------------
    func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }

    func cardHeader(_ title: String, trailing: String? = nil) -> some View {
        HStack {
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer()
            if let t = trailing { Text(t).font(.system(size: 10)).foregroundColor(.secondary) }
        }
    }

    func stat(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(k).font(.system(size: 9, weight: .semibold)).tracking(0.5).foregroundColor(.secondary)
            Text(v).font(.system(size: 16, weight: .semibold, design: .rounded))
        }
    }

    func busy(_ t: String) -> some View {
        HStack(spacing: 8) { ProgressView().scaleEffect(0.6); Text(t).font(.system(size: 12)).foregroundColor(.secondary) }
    }

    func primaryButton(_ title: String, running: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent).tint(ACCENT).controlSize(.large).disabled(running)
    }

    @ViewBuilder func verdictBox(_ v: String) -> some View {
        let (c, icon, t): (Color, String, String) = {
            switch v {
            case "local":  return (RED, "wifi.exclamationmark", "Likely you — your wifi/local link. Move closer, try 5GHz, or reconnect.")
            case "bloat":  return (RED, "speedometer", "Bufferbloat — something is saturating your link. Pause big transfers.")
            case "remote": return (AMBER, "network", "Your ISP / upstream path is degraded. Local link is clean.")
            default:        return (GREEN, "checkmark.circle.fill", "Your side is clean — most likely the other end or the call server.")
            }
        }()
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundColor(c)
            Text(t).font(.system(size: 12))
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(c.opacity(0.13), in: RoundedRectangle(cornerRadius: 10))
    }
}

// ── App bootstrap ───────────────────────────────────────────────────
class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let model = WifiModel()
    func applicationDidFinishLaunching(_ note: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "WiFi Health"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
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
