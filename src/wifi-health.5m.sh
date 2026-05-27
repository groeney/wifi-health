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
NO_INTERNET=0
IS_HOTSPOT=0
LATENCY_AVG=""
LATENCY_JITTER=""
PACKET_LOSS=""

check_hotspot() {
    # Heuristic SSID match for personal hotspots — names like
    # "James's iPhone", "Pixel 8", "Galaxy S23", "Mike's Hotspot".
    case "$SSID" in
        *iPhone*|*iPad*|*Android*|*Pixel*|*Galaxy*|*Mobile*|*hotspot*|*Hotspot*|*HOTSPOT*)
            IS_HOTSPOT=1
            ;;
    esac
}

check_internet_and_latency() {
    # Combined reachability + quality check. Five rapid pings give us:
    #   - Is the internet reachable? (any reply at all)
    #   - Latency average
    #   - Jitter (stddev — smoothest measure of variation)
    #   - Packet loss
    # This is the most important signal in the whole script: a great
    # wifi link to a bad upstream (hotspot with weak LTE, congested
    # cafe wifi, etc.) lies through its teeth on link metrics alone.
    local out loss stats avg stddev
    out=$(ping -c 5 -i 0.2 -W 1 1.1.1.1 2>/dev/null)

    # macOS ping with -i 0.2 only prints the summary (sub-second
    # intervals need root for per-packet output), so we look for the
    # "packets transmitted" line to confirm ping actually ran.
    if [ -z "$out" ] || ! echo "$out" | grep -q "packets transmitted"; then
        # Ping totally failed — try TCP for reachability.
        if nc -z -w 3 1.1.1.1 443 2>/dev/null; then
            return  # TCP works but ICMP blocked — can't measure latency
        fi
        NO_INTERNET=1
        RECS+=("No internet — try a hotspot, sign in to the network, or find another connection")
        LEVS+=("high")
        return
    fi

    loss=$(echo "$out" | awk -F'[%]' '/packet loss/ {print $1}' | awk '{print $NF}')
    loss=${loss:-100}
    loss=${loss%.*}  # strip any decimal

    # 100% loss means no connectivity even though ping ran.
    if [ "$loss" -eq 100 ] 2>/dev/null; then
        NO_INTERNET=1
        RECS+=("No internet — try a hotspot, sign in to the network, or find another connection")
        LEVS+=("high")
        return
    fi

    stats=$(echo "$out" | grep -E 'min/avg/max')
    # Format: round-trip min/avg/max/stddev = 21.3/27.6/39.7/5.1 ms
    avg=$(echo "$stats" | awk -F'=' '{print $2}' | awk -F'/' '{print $2}' | cut -d. -f1)
    stddev=$(echo "$stats" | awk -F'=' '{print $2}' | awk -F'/' '{print $4}' | cut -d. -f1)
    avg=${avg:-0}
    stddev=${stddev:-0}

    LATENCY_AVG=$avg
    LATENCY_JITTER=$stddev
    PACKET_LOSS=$loss

    # Packet loss
    if [ "$loss" -gt 10 ] 2>/dev/null; then
        RECS+=("High packet loss (${loss}%) — connection is unreliable")
        LEVS+=("high")
    elif [ "$loss" -gt 2 ] 2>/dev/null; then
        RECS+=("Some packet loss (${loss}%)")
        LEVS+=("medium")
    fi

    # Latency
    if [ "$avg" -gt 150 ] 2>/dev/null; then
        RECS+=("Very high latency (${avg}ms) — calls and pages will be sluggish")
        LEVS+=("high")
    elif [ "$avg" -gt 60 ] 2>/dev/null; then
        RECS+=("Elevated latency (${avg}ms)")
        LEVS+=("medium")
    fi

    # Jitter
    if [ "$stddev" -gt 50 ] 2>/dev/null; then
        RECS+=("High jitter (±${stddev}ms) — bad for video calls and gaming")
        LEVS+=("high")
    elif [ "$stddev" -gt 20 ] 2>/dev/null; then
        RECS+=("Moderate jitter (±${stddev}ms)")
        LEVS+=("medium")
    fi
}

check_captive_portal() {
    # Skip if we already know there's no internet at all.
    [ "$NO_INTERNET" -eq 1 ] && return
    # Use Apple's captive portal endpoint. A real connection returns
    # exactly "<HTML>...<TITLE>Success</TITLE>...</HTML>".
    # Portals intercept this with a redirect or login page.
    # Drop -f so we get the response body even on redirects.
    local resp
    resp=$(curl -sS --max-time 4 -o - "http://captive.apple.com/hotspot-detect.html" 2>/dev/null)
    local rc=$?
    if [ $rc -ne 0 ]; then
        RECS+=("Network is blocking web traffic — check for a login page")
        LEVS+=("high")
    elif ! echo "$resp" | grep -q "<TITLE>Success</TITLE>"; then
        RECS+=("Captive portal detected — open a browser to sign in")
        LEVS+=("high")
    fi
}

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
    # Skip link speed checks on hotspots — link rate to the phone is
    # almost always fast and tells us nothing about actual throughput.
    [ "$IS_HOTSPOT" -eq 1 ] && return
    if [ "$TX_RATE" -lt 50 ] 2>/dev/null; then
        RECS+=("Link speed very low (${TX_RATE} Mbps) — check router or band")
        LEVS+=("high")
    elif [ "$TX_RATE" -lt 100 ] 2>/dev/null; then
        RECS+=("Link speed is modest (${TX_RATE} Mbps)")
        LEVS+=("medium")
    fi
}

check_hotspot_advice() {
    [ "$IS_HOTSPOT" -ne 1 ] && return
    # On a hotspot, the real bottleneck is the phone's cellular signal,
    # not the wifi link. Add a contextual hint if performance is bad.
    if [ -n "$LATENCY_AVG" ] && [ "$LATENCY_AVG" -gt 80 ] 2>/dev/null; then
        RECS+=("On a hotspot — speed is capped by your phone's cellular signal, try moving it nearer a window")
        LEVS+=("medium")
    fi
    # Suggest switching to known wifi if any are nearby.
    local preferred nearby match
    preferred=$(networksetup -listpreferredwirelessnetworks en0 2>/dev/null | tail -n +2 | sed 's/^[[:space:]]*//')
    if [ -n "$preferred" ]; then
        # Cached scan of currently visible networks (no fresh scan to keep it fast).
        nearby=$(system_profiler SPAirPortDataType 2>/dev/null | awk '
            /Other Local Wi-Fi Networks:/ {flag=1; next}
            /^[[:space:]]{8}[A-Z]/ {flag=0}
            flag && /^[[:space:]]{12}[^[:space:]]/ {gsub(/:$/, ""); gsub(/^[[:space:]]+/, ""); print}
        ' | sort -u)
        if [ -n "$nearby" ]; then
            while IFS= read -r net; do
                [ -z "$net" ] && continue
                [ "$net" = "$SSID" ] && continue
                if echo "$nearby" | grep -qFx "$net"; then
                    match="$net"
                    break
                fi
            done <<< "$preferred"
            if [ -n "$match" ]; then
                RECS+=("Known network '$match' is in range — switch for likely better speeds")
                LEVS+=("high")
            fi
        fi
    fi
}

# ── Run all checks ──────────────────────────────────────────────────
# Order matters: hotspot detection first (others reference IS_HOTSPOT),
# then reachability+latency (the highest-signal check), then link.
check_hotspot
check_internet_and_latency
check_captive_portal
check_band
check_signal
check_noise
check_link_speed
check_hotspot_advice

# ── Score ───────────────────────────────────────────────────────────
HIGH=0
MED=0
for lev in "${LEVS[@]}"; do
    [ "$lev" = "high" ] && ((HIGH++))
    [ "$lev" = "medium" ] && ((MED++))
done

# Link-layer signal quality
if [ "$RSSI" -gt -60 ] && [ "$SNR" -gt 25 ] 2>/dev/null; then
    SIG="good"
elif [ "$RSSI" -gt -72 ] && [ "$SNR" -gt 15 ] 2>/dev/null; then
    SIG="ok"
else
    SIG="poor"
fi

# End-to-end quality from ping. Empty values mean we couldn't measure
# (e.g. ICMP blocked) — treat as "ok" rather than poor.
QUAL="ok"
if [ -n "$LATENCY_AVG" ] && [ -n "$PACKET_LOSS" ]; then
    if [ "$PACKET_LOSS" -le 1 ] 2>/dev/null && [ "$LATENCY_AVG" -lt 50 ] 2>/dev/null && [ "${LATENCY_JITTER:-0}" -lt 15 ] 2>/dev/null; then
        QUAL="good"
    elif [ "$PACKET_LOSS" -gt 10 ] 2>/dev/null || [ "$LATENCY_AVG" -gt 200 ] 2>/dev/null; then
        QUAL="poor"
    fi
fi

# ── Color logic ─────────────────────────────────────────────────────
# Priority order:
#   1. No internet → RED
#   2. Actually-broken connection (poor end-to-end quality + fixes) → RED
#   3. High-leverage fixes available → YELLOW
#   4. Everything good → GREEN
if [ "$NO_INTERNET" -eq 1 ]; then
    COLOR="#F44336"; LABEL="No Internet"; MSG="Connected to wifi but can't reach the web"
elif [ "$QUAL" = "poor" ] && [ "$HIGH" -gt 0 ]; then
    COLOR="#F44336"; LABEL="Needs Attention"; MSG="Real-world performance is bad — clear things to try"
elif [ "$QUAL" = "poor" ]; then
    COLOR="#FF9800"; LABEL="Slow"; MSG="Connection feels slow — limited options to improve"
elif [ "$SIG" = "good" ] && [ "$QUAL" = "good" ] && [ "$HIGH" -eq 0 ] && [ "$MED" -eq 0 ]; then
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
SSID_DISPLAY="$SSID"
[ "$IS_HOTSPOT" -eq 1 ] && SSID_DISPLAY="$SSID (hotspot)"

echo "● | size=14 color=$COLOR"
echo "---"
echo "$SSID_DISPLAY — $LABEL | size=13"
echo "$MSG | size=11 color=#888888"
echo "---"
if [ -n "$LATENCY_AVG" ]; then
    echo "Latency:     ${LATENCY_AVG} ms (±${LATENCY_JITTER}) | font=Menlo size=11"
    echo "Loss:        ${PACKET_LOSS}% | font=Menlo size=11"
fi
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
