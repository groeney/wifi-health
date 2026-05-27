#!/bin/bash
# wifi-health.10s.sh — SwiftBar plugin
# Refreshes every 10 seconds. Heavy checks (ping, captive portal,
# known-network scan) run at most once every 5 minutes; their results
# are persisted in a state file so each cycle stays cheap.

HELPER_DIR="$HOME/Library/Application Support/SwiftBar"
HELPER="$HELPER_DIR/wifi-info"
ACTIONS="$HELPER_DIR/wifi-actions.sh"
STATE_FILE="$HELPER_DIR/wifi-health.state"
HEAVY_INTERVAL=300

if [ ! -x "$HELPER" ]; then
    echo "● | size=14 color=#999999"
    echo "---"
    echo "wifi-info binary missing — run install.sh"
    exit 0
fi

# ── Gather wifi metrics (instant) ───────────────────────────────────
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

# ── State ───────────────────────────────────────────────────────────
RECS=()
LEVS=()
NO_INTERNET=0
IS_HOTSPOT=0
LATENCY_AVG=""
LATENCY_JITTER=""
PACKET_LOSS=""
CAPTIVE_DETECTED=0
PORTAL_BLOCKED=0
KNOWN_NEARBY=""

ACT_PORTAL=0
ACT_RECONNECT=0
ACT_SWITCH=""

LAST_HEAVY=0
[ -f "$STATE_FILE" ] && . "$STATE_FILE"

# ── Helpers ─────────────────────────────────────────────────────────
save_state() {
    # Persist the heavy-check results so the next refresh can use them.
    # printf %q on KNOWN_NEARBY handles spaces and apostrophes safely.
    {
        printf 'LAST_HEAVY=%s\n'        "$NOW"
        printf 'NO_INTERNET=%s\n'       "$NO_INTERNET"
        printf 'LATENCY_AVG=%s\n'       "$LATENCY_AVG"
        printf 'LATENCY_JITTER=%s\n'    "$LATENCY_JITTER"
        printf 'PACKET_LOSS=%s\n'       "$PACKET_LOSS"
        printf 'CAPTIVE_DETECTED=%s\n'  "$CAPTIVE_DETECTED"
        printf 'PORTAL_BLOCKED=%s\n'    "$PORTAL_BLOCKED"
        printf 'KNOWN_NEARBY=%q\n'      "$KNOWN_NEARBY"
    } > "$STATE_FILE"
}

# ── Checks ──────────────────────────────────────────────────────────
# Each check pair is split:
#   measure_X   — slow (network I/O). Runs only on heavy cycles.
#   interpret_X — cheap. Runs every cycle, using fresh or cached data.
# Pure link-layer checks (band/signal/noise/link_speed/hotspot) are
# cheap enough to stay as single functions.

check_hotspot() {
    case "$SSID" in
        *iPhone*|*iPad*|*Android*|*Pixel*|*Galaxy*|*Mobile*|*hotspot*|*Hotspot*|*HOTSPOT*)
            IS_HOTSPOT=1
            ;;
    esac
}

measure_internet_and_latency() {
    local out loss stats avg stddev
    out=$(ping -c 5 -i 0.2 -W 1 1.1.1.1 2>/dev/null)
    if [ -z "$out" ] || ! echo "$out" | grep -q "packets transmitted"; then
        nc -z -w 3 1.1.1.1 443 2>/dev/null && return
        NO_INTERNET=1
        return
    fi
    loss=$(echo "$out" | awk -F'[%]' '/packet loss/ {print $1}' | awk '{print $NF}')
    loss=${loss:-100}
    loss=${loss%.*}
    if [ "$loss" -eq 100 ] 2>/dev/null; then
        NO_INTERNET=1
        return
    fi
    stats=$(echo "$out" | grep -E 'min/avg/max')
    avg=$(echo "$stats" | awk -F'=' '{print $2}' | awk -F'/' '{print $2}' | cut -d. -f1)
    stddev=$(echo "$stats" | awk -F'=' '{print $2}' | awk -F'/' '{print $4}' | cut -d. -f1)
    LATENCY_AVG=${avg:-0}
    LATENCY_JITTER=${stddev:-0}
    PACKET_LOSS=$loss
}

interpret_internet_and_latency() {
    if [ "$NO_INTERNET" -eq 1 ]; then
        RECS+=("No internet — try a hotspot, sign in to the network, or find another connection")
        LEVS+=("high")
        ACT_PORTAL=1
        ACT_RECONNECT=1
        return
    fi
    [ -z "$PACKET_LOSS" ] && return

    if [ "$PACKET_LOSS" -gt 10 ] 2>/dev/null; then
        RECS+=("High packet loss (${PACKET_LOSS}%) — connection is unreliable")
        LEVS+=("high")
        ACT_RECONNECT=1
    elif [ "$PACKET_LOSS" -gt 2 ] 2>/dev/null; then
        RECS+=("Some packet loss (${PACKET_LOSS}%)")
        LEVS+=("medium")
    fi
    if [ "$LATENCY_AVG" -gt 150 ] 2>/dev/null; then
        RECS+=("Very high latency (${LATENCY_AVG}ms) — calls and pages will be sluggish")
        LEVS+=("high")
    elif [ "$LATENCY_AVG" -gt 60 ] 2>/dev/null; then
        RECS+=("Elevated latency (${LATENCY_AVG}ms)")
        LEVS+=("medium")
    fi
    if [ "${LATENCY_JITTER:-0}" -gt 50 ] 2>/dev/null; then
        RECS+=("High jitter (±${LATENCY_JITTER}ms) — bad for video calls and gaming")
        LEVS+=("high")
    elif [ "${LATENCY_JITTER:-0}" -gt 20 ] 2>/dev/null; then
        RECS+=("Moderate jitter (±${LATENCY_JITTER}ms)")
        LEVS+=("medium")
    fi
}

measure_captive_portal() {
    [ "$NO_INTERNET" -eq 1 ] && return
    local resp rc
    resp=$(curl -sS --max-time 4 -o - "http://captive.apple.com/hotspot-detect.html" 2>/dev/null)
    rc=$?
    if [ $rc -ne 0 ]; then
        PORTAL_BLOCKED=1
    elif ! echo "$resp" | grep -q "<TITLE>Success</TITLE>"; then
        CAPTIVE_DETECTED=1
    fi
}

interpret_captive_portal() {
    if [ "$PORTAL_BLOCKED" -eq 1 ]; then
        RECS+=("Network is blocking web traffic — check for a login page")
        LEVS+=("high")
        ACT_PORTAL=1
    elif [ "$CAPTIVE_DETECTED" -eq 1 ]; then
        RECS+=("Captive portal detected — open a browser to sign in")
        LEVS+=("high")
        ACT_PORTAL=1
    fi
}

measure_known_nearby() {
    [ "$IS_HOTSPOT" -ne 1 ] && return
    local preferred nearby
    preferred=$(networksetup -listpreferredwirelessnetworks en0 2>/dev/null | tail -n +2 | sed 's/^[[:space:]]*//')
    [ -z "$preferred" ] && return
    nearby=$(system_profiler SPAirPortDataType 2>/dev/null | awk '
        /Other Local Wi-Fi Networks:/ {flag=1; next}
        /^[[:space:]]{8}[A-Z]/ {flag=0}
        flag && /^[[:space:]]{12}[^[:space:]]/ {gsub(/:$/, ""); gsub(/^[[:space:]]+/, ""); print}
    ' | sort -u)
    [ -z "$nearby" ] && return
    while IFS= read -r net; do
        [ -z "$net" ] && continue
        [ "$net" = "$SSID" ] && continue
        if echo "$nearby" | grep -qFx "$net"; then
            KNOWN_NEARBY="$net"
            return
        fi
    done <<< "$preferred"
}

interpret_known_nearby() {
    [ "$IS_HOTSPOT" -ne 1 ] && return
    if [ -n "$LATENCY_AVG" ] && [ "$LATENCY_AVG" -gt 80 ] 2>/dev/null; then
        RECS+=("On a hotspot — speed is capped by your phone's cellular signal, try moving it nearer a window")
        LEVS+=("medium")
    fi
    if [ -n "$KNOWN_NEARBY" ]; then
        RECS+=("Known network '$KNOWN_NEARBY' is in range — switch for likely better speeds")
        LEVS+=("high")
        ACT_SWITCH="$KNOWN_NEARBY"
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
    [ "$IS_HOTSPOT" -eq 1 ] && return
    if [ "$TX_RATE" -lt 50 ] 2>/dev/null; then
        RECS+=("Link speed very low (${TX_RATE} Mbps) — check router or band")
        LEVS+=("high")
    elif [ "$TX_RATE" -lt 100 ] 2>/dev/null; then
        RECS+=("Link speed is modest (${TX_RATE} Mbps)")
        LEVS+=("medium")
    fi
}

# ── Run checks ──────────────────────────────────────────────────────
check_hotspot

NOW=$(date +%s)
if (( NOW - LAST_HEAVY > HEAVY_INTERVAL )); then
    # Reset cached values before remeasuring so partial failures don't
    # carry forward stale data.
    NO_INTERNET=0
    LATENCY_AVG=""; LATENCY_JITTER=""; PACKET_LOSS=""
    CAPTIVE_DETECTED=0; PORTAL_BLOCKED=0
    KNOWN_NEARBY=""

    measure_internet_and_latency
    measure_captive_portal
    measure_known_nearby
    save_state
fi

# Interpretations always run, using fresh or cached measurements.
interpret_internet_and_latency
interpret_captive_portal
interpret_known_nearby
check_band
check_signal
check_noise
check_link_speed

# ── Score ───────────────────────────────────────────────────────────
HIGH=0; MED=0
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

QUAL="ok"
if [ -n "$LATENCY_AVG" ] && [ -n "$PACKET_LOSS" ]; then
    if [ "$PACKET_LOSS" -le 1 ] 2>/dev/null && [ "$LATENCY_AVG" -lt 50 ] 2>/dev/null && [ "${LATENCY_JITTER:-0}" -lt 15 ] 2>/dev/null; then
        QUAL="good"
    elif [ "$PACKET_LOSS" -gt 10 ] 2>/dev/null || [ "$LATENCY_AVG" -gt 200 ] 2>/dev/null; then
        QUAL="poor"
    fi
fi

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
# The colored dot is health-only. The activity arrow lives in the
# separate wifi-activity.5s.sh plugin (smaller, gray, ambient FYI).
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

if [ "$ACT_PORTAL" -eq 1 ] || [ "$ACT_RECONNECT" -eq 1 ] || [ -n "$ACT_SWITCH" ]; then
    echo "---"
    echo "Quick fixes | size=11 color=#888888"
    if [ "$ACT_PORTAL" -eq 1 ]; then
        echo "🔓 Open login page | shell=\"$ACTIONS\" param1=portal terminal=false size=12"
    fi
    if [ -n "$ACT_SWITCH" ]; then
        echo "📶 Switch to $ACT_SWITCH | shell=\"$ACTIONS\" param1=switch param2=\"$ACT_SWITCH\" terminal=false refresh=true size=12"
    fi
    if [ "$ACT_RECONNECT" -eq 1 ]; then
        echo "🔄 Reconnect wifi | shell=\"$ACTIONS\" param1=reconnect terminal=false refresh=true size=12"
    fi
fi

echo "---"
echo "Run speed test… | shell=\"$ACTIONS\" param1=speed-test terminal=false size=11 color=#888888"
echo "Wi-Fi settings… | shell=\"$ACTIONS\" param1=settings terminal=false size=11 color=#888888"
echo "Refresh | refresh=true size=11 color=#888888"
