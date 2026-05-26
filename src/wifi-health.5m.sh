#!/bin/bash
# wifi-health.5m.sh — SwiftBar plugin
# Refreshes every 5 minutes (filename encodes interval).
# Drop into your SwiftBar plugins folder.

HELPER_DIR="$HOME/Library/Application Support/SwiftBar"
HELPER="$HELPER_DIR/wifi-info"

if [ ! -x "$HELPER" ]; then
    echo "● | size=14 color=#999999"
    echo "---"
    echo "wifi-info binary missing — run install.sh"
    exit 0
fi

# ── Gather metrics ──────────────────────────────────────────────────
eval "$("$HELPER")"

if [ "$STATUS" != "on" ]; then
    echo "● | size=14 color=#999999"
    echo "---"
    echo "WiFi is off"
    exit 0
fi

SSID=$(networksetup -getairportnetwork en0 2>/dev/null | sed 's/Current Wi-Fi Network: //')
[ -z "$SSID" ] && SSID="Unknown"
SNR=$((RSSI - NOISE))

# ── Checks ──────────────────────────────────────────────────────────
# Each check function appends to RECS[] (recommendation text) and
# LEVS[] (priority: "high" or "medium"). To add a new check, define
# a function and call it below.

RECS=()
LEVS=()

check_band() {
    if [ "$BAND" = "2.4GHz" ]; then
        RECS+=("Switch to 5GHz — less interference, faster speeds")
        LEVS+=("high")
    fi
}

check_signal() {
    if [ "$RSSI" -lt -78 ] 2>/dev/null; then
        RECS+=("Very weak signal — move closer to router or add an extender")
        LEVS+=("high")
    elif [ "$RSSI" -lt -70 ] 2>/dev/null; then
        RECS+=("Moderate signal — moving closer to router would help")
        LEVS+=("medium")
    fi
}

check_noise() {
    if [ "$SNR" -lt 15 ] 2>/dev/null; then
        RECS+=("High noise — try changing router channel or relocating it")
        LEVS+=("high")
    elif [ "$SNR" -lt 20 ] 2>/dev/null; then
        RECS+=("Moderate noise — a channel change might help")
        LEVS+=("medium")
    fi
}

check_link_speed() {
    if [ "$TX_RATE" -lt 50 ] 2>/dev/null; then
        RECS+=("Link speed very low (${TX_RATE} Mbps) — check router or band")
        LEVS+=("high")
    elif [ "$TX_RATE" -lt 100 ] 2>/dev/null; then
        RECS+=("Link speed is modest (${TX_RATE} Mbps)")
        LEVS+=("medium")
    fi
}

check_captive_portal() {
    # Detect captive portals (hotel/airport/cafe login walls).
    # A quick HTTP check against Apple's captive portal detection endpoint.
    local resp
    resp=$(curl -fsS --max-time 3 "http://captive.apple.com/hotspot-detect.html" 2>/dev/null)
    if [ $? -ne 0 ]; then
        RECS+=("Network may be blocking traffic — check for a login page")
        LEVS+=("high")
    elif ! echo "$resp" | grep -q "Success"; then
        RECS+=("Captive portal detected — open a browser to sign in")
        LEVS+=("high")
    fi
}

# ── Run all checks ──────────────────────────────────────────────────
# Add new check_* calls here:
check_band
check_signal
check_noise
check_link_speed
check_captive_portal

# ── Score ───────────────────────────────────────────────────────────
HIGH=0
MED=0
for lev in "${LEVS[@]}"; do
    [ "$lev" = "high" ] && ((HIGH++))
    [ "$lev" = "medium" ] && ((MED++))
done

if [ "$RSSI" -gt -60 ] && [ "$SNR" -gt 25 ] 2>/dev/null; then
    SIG="good"
elif [ "$RSSI" -gt -72 ] && [ "$SNR" -gt 15 ] 2>/dev/null; then
    SIG="ok"
else
    SIG="poor"
fi

# ── Color logic ─────────────────────────────────────────────────────
# GREEN  — connection is solid, nothing to fix
# YELLOW — some improvements possible, or weak but nothing actionable
# RED    — poor + clear things you can fix right now
if [ "$SIG" = "good" ] && [ "$HIGH" -eq 0 ] && [ "$MED" -eq 0 ]; then
    COLOR="#4CAF50"; LABEL="Good"; MSG="You're good"
elif [ "$HIGH" -gt 0 ] && [ "$SIG" = "poor" ]; then
    COLOR="#F44336"; LABEL="Needs Attention"; MSG="You can really improve your connection"
elif [ "$HIGH" -gt 0 ]; then
    COLOR="#FF9800"; LABEL="Can Improve"; MSG="High-impact improvements available"
elif [ "$SIG" = "poor" ]; then
    COLOR="#FF9800"; LABEL="Limited"; MSG="Connection is weak — not much to do besides finding a better spot"
elif [ "$MED" -gt 0 ]; then
    COLOR="#FF9800"; LABEL="OK"; MSG="Some improvements possible"
else
    COLOR="#4CAF50"; LABEL="Good"; MSG="You're good"
fi

# ── Render ──────────────────────────────────────────────────────────
echo "● | size=14 color=$COLOR"
echo "---"
echo "$SSID — $LABEL | size=13"
echo "$MSG | size=11 color=#888888"
echo "---"
echo "Signal:      ${RSSI} dBm | font=Menlo size=11"
echo "Noise:       ${NOISE} dBm | font=Menlo size=11"
echo "SNR:         ${SNR} dB | font=Menlo size=11"
echo "Channel:     ${CHANNEL} ($BAND) | font=Menlo size=11"
echo "Link Speed:  ${TX_RATE} Mbps | font=Menlo size=11"

if [ ${#RECS[@]} -gt 0 ]; then
    echo "---"
    for i in "${!RECS[@]}"; do
        if [ "${LEVS[$i]}" = "high" ]; then
            echo "⚡ ${RECS[$i]} | color=#F44336 size=12"
        else
            echo "→ ${RECS[$i]} | color=#FF9800 size=12"
        fi
    done
else
    echo "---"
    echo "✓ No improvements needed | color=#4CAF50 size=12"
fi

echo "---"
echo "Refresh | refresh=true size=12"
