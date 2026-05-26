# wifi-health

A macOS menu bar widget that shows your wifi connection quality at a glance.

A colored dot sits in your menu bar:

- **Green** — you're good, nothing to fix
- **Yellow** — some improvements possible, or weak but nothing actionable
- **Red** — attention needed, high-impact fixes available

Click the dot for signal metrics, noise levels, and specific recommendations.

## Install

```bash
git clone git@github.com:jamesgroeneveld/wifi-health.git
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

The plugin runs every 5 minutes and evaluates your connection against a set of checks:

| Check | What it looks at |
|-------|-----------------|
| `check_band` | Are you on 2.4GHz when 5GHz would be better? |
| `check_signal` | Is RSSI too weak? |
| `check_noise` | Is signal-to-noise ratio poor? |
| `check_link_speed` | Is the link rate unusually low? |
| `check_captive_portal` | Are you stuck behind a login wall? |

Each check can flag a **high** or **medium** priority recommendation.
The dot color is determined by combining signal quality with how many
high-leverage fixes are available.

## Adding checks

Open `src/wifi-health.5m.sh`. Each check is a bash function that appends
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
