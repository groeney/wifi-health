# wifi-health

A macOS menu bar widget that shows your wifi connection quality at a glance.

A small icon sits in your menu bar:

- The **colored dot** shows connection health:
  - **Green** — you're good, nothing to fix
  - **Yellow** — some improvements possible, or weak but nothing actionable
  - **Red** — attention needed, high-impact fixes available
- A **muted gray arrow** (`↓` / `↑` / `⇅`) is tucked next to the dot when
  there's notable network traffic (>10 KB/s in or out). Nothing appears
  next to the dot when the network is idle.

The icon is rendered as a single PNG (generated at install time, twelve
variants total) so the colored dot and gray arrow share one menu bar
slot and stay flush together regardless of SwiftBar's inter-item
spacing.

Click the icon for a compact menu: the headline status plus any
actionable recommendations, with raw metrics (**Details**) and tools
(**More**) tucked into submenus. **Advanced & call quality…** pops out a
native window with live metrics and the call-quality diagnosis (see
below) — kept out of the menu so it stays lean.

## Install

```bash
git clone git@github.com:groeney/wifi-health.git
cd wifi-health
bash install.sh
```

Requires Homebrew and Xcode Command Line Tools (`xcode-select --install`).

The installer will:
1. Install [SwiftBar](https://github.com/swiftbar/SwiftBar) if needed
2. Compile a small Swift helper that reads wifi metrics via CoreWLAN
3. Drop the plugin script into SwiftBar's plugins folder
4. Launch SwiftBar

## Update

```bash
bash update.sh
```

Pulls latest from git and re-runs the installer.

## Uninstall

```bash
bash uninstall.sh
```

## How it works

The plugin refreshes every 10 seconds. **Connection quality**
(reachability, latency, jitter, packet loss) and the activity meter are
measured **every cycle** so the dot reacts in real time — e.g. it turns
yellow/red within ~10s if your path goes choppy mid-call. The slower,
rarely-changing checks (captive portal, DNS/HTTPS reachability, scanning
for known networks) run at most once every 5 minutes and are cached in
`~/Library/Application Support/SwiftBar/wifi-health.state`.

Checks:

| Check | What it looks at |
|-------|-----------------|
| `check_hotspot` | Are you on a personal hotspot? (changes how other checks interpret things) |
| `sample_throughput` | Current down/up bytes per second — drives the live activity arrow |
| `measure_internet_and_latency` | Can you actually reach the internet? What's the latency, jitter, and packet loss? |
| `measure_captive_portal` | Are you stuck behind a login wall? |
| `measure_dns_and_https` | Can DNS resolve and HTTPS pages actually load? Catches "ping works but sites won't" failures |
| `measure_known_nearby` | If on a hotspot — is one of your saved wifi networks in range? |
| `check_band` | Are you on 2.4GHz when 5GHz would be better? |
| `check_signal` | Is RSSI too weak? |
| `check_noise` | Is signal-to-noise ratio poor? |
| `check_link_speed` | Is the link rate unusually low? |

The most important signal is **end-to-end performance** (latency, jitter, packet loss),
not the wifi link metrics. A great wifi link to a bad upstream — like a hotspot with
weak LTE, or a Caltrain network that doesn't route — looks perfect on link metrics alone.

Each check can flag a **high** or **medium** priority recommendation.
The dot color is determined by combining link quality, end-to-end quality, and
how many high-leverage fixes are available.

## One-click fixes

The dropdown shows clickable remediations when they're relevant:

| Action | When it shows | What it does |
|--------|--------------|--------------|
| 🔓 **Open login page** | Captive portal detected, or no internet | Opens `http://<gateway-ip>/` (DNS-free, works even when the portal blocks DNS) plus Apple's captive detection URL as backup |
| 📶 **Switch to [network]** | On a hotspot with a known wifi network in range | Joins the known network (password comes from keychain) |
| 🔄 **Reconnect wifi** | No internet, or high packet loss | Toggles wifi off/on — fixes stuck DHCP leases and stale routes |
| **Advanced & call quality…** | Always available | Pops out a native window with live metrics and a call-quality check (per-hop loss/jitter + an "is it you?" verdict). See below. |
| **Run speed test…** | Always available | Runs Apple's `networkQuality` test in Terminal (10-20s) |
| **Wi-Fi settings…** | Always available | Opens the Wi-Fi pane in System Settings |

### "Is it me?" — diagnosing a bad video call

Open **Advanced & call quality…** from the menu — a native window
(`src/dashboard.swift`, compiled into `WifiHealth.app` at install) with
live metrics and a **Run call-quality check** button. The button runs a
~15s probe and shows the per-hop breakdown + verdict right there, live —
no Terminal, no menu refresh dance. `bash src/diagnose-call.sh` still
prints the same thing as a terminal report.

A choppy call can be your wifi, your ISP, a saturated link, or the far
end (the other person / the call server). We can't see their connection,
but the probe measures and decomposes *your* path to localize the fault:

- Loss/jitter on the **router** hop → it's **your wifi/local link** (move
  closer, switch to 5GHz, reduce interference, reconnect)
- Router clean but **remote** hops bad → it's your **ISP/upstream**
- Latency balloons **under load** → **bufferbloat**; something is
  saturating your link (check the activity arrows)
- **Everything clean** → it's almost certainly **the other participant or
  the call server** — not something you can fix

The real-time dot complements this: if the choppiness is on your side,
the dot should already be yellow/red with the jitter/loss called out.

All actions are non-destructive and don't require `sudo`. Implementations
live in `src/wifi-actions.sh` — easy to extend with new remediations.

## Adding checks

Open `src/wifi-health.10s.sh`. Each check is a bash function that appends
to two arrays:

```bash
check_your_new_thing() {
    if some_condition; then
        RECS+=("Description of what to do")
        LEVS+=("high")   # or "medium"
    fi
}
```

Then add `check_your_new_thing` to the "Run all checks" section.
Run `bash install.sh` to deploy your changes.

## Development

`bash traffic-sim.sh` generates **real** network traffic at stepped rates
via Cloudflare's speed endpoints (all data discarded), so you can watch the
live menu bar arrows respond. Takes `down` / `up` / `both` / `all`, and a
`HOLD` env override for how long each stage is held.

The icon's level→(size, weight) mapping lives in `src/gen-icon.swift`
(`levelSpecs`); the rate→level thresholds live in `rate_to_level` in both
`src/wifi-health.10s.sh` and `traffic-sim.sh` — keep them in sync.
