# wifi-health

A macOS menu bar widget that shows your wifi connection quality at a glance.

Two small items sit in your menu bar:

- **`●`** (the health dot) — green / yellow / red:
  - **Green** — you're good, nothing to fix
  - **Yellow** — some improvements possible, or weak but nothing actionable
  - **Red** — attention needed, high-impact fixes available
- **`↓ ↑ ⇅ ·`** (the activity meter, in a muted gray) — shows current
  network traffic at a glance. The arrow appears when traffic exceeds
  10 KB/s in a direction; otherwise a tiny middle dot indicates the
  meter is alive but quiet.

Click either item for details. The health dot's dropdown has signal
metrics, latency, noise, and remediations; the activity item's dropdown
shows current down/up rates.

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

The plugin refreshes every 10 seconds, but does the expensive checks
(ping, captive portal detection, scanning for known networks) at most
once every 5 minutes. Their results are cached in a small state file
at `~/Library/Application Support/SwiftBar/wifi-health.state`. Cheap
work — pulling wifi metrics from CoreWLAN, sampling byte counters for
the activity meter — runs every cycle.

Checks:

| Check | What it looks at |
|-------|-----------------|
| `check_hotspot` | Are you on a personal hotspot? (changes how other checks interpret things) |
| `sample_throughput` | Current down/up bytes per second — drives the live activity arrow |
| `measure_internet_and_latency` | Can you actually reach the internet? What's the latency, jitter, and packet loss? |
| `measure_captive_portal` | Are you stuck behind a login wall? |
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
| **Run speed test…** | Always available | Runs Apple's `networkQuality` test in Terminal (10-20s) |
| **Wi-Fi settings…** | Always available | Opens the Wi-Fi pane in System Settings |

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
