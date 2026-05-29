#!/bin/bash
# wifi-health.10s.sh — SwiftBar plugin
# Refreshes every 10 seconds. Heavy checks (ping, captive portal,
# known-network scan) run at most once every 5 minutes; their results
# are persisted in a state file so each cycle stays cheap.

HELPER_DIR="$HOME/Library/Application Support/SwiftBar"
HELPER="$HELPER_DIR/wifi-info"
ACTIONS="$HELPER_DIR/wifi-actions.sh"
ICONS_DIR="$HELPER_DIR/icons"
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
DNS_BROKEN=0
HTTPS_BROKEN=0

ACT_PORTAL=0
ACT_RECONNECT=0
ACT_SWITCH=""

BYTES_IN_RATE=0
BYTES_OUT_RATE=0

LAST_HEAVY=0
[ -f "$STATE_FILE" ] && . "$STATE_FILE"

# ── Helpers ─────────────────────────────────────────────────────────
format_rate() {
    awk -v b="$1" 'BEGIN {
        if (b < 1024)             printf "%dB", b
        else if (b < 1048576)     printf "%dK", b/1024 + 0.5
        else if (b < 1073741824)  printf "%.1fM", b/1048576
        else                      printf "%.1fG", b/1073741824
    }'
}

sample_throughput() {
    # Two interface byte-counter samples 1s apart → instantaneous rate.
    local in1 out1 in2 out2
    read -r in1 out1 < <(netstat -bI en0 2>/dev/null | awk '$1=="en0" {print $7, $10; exit}')
    sleep 1
    read -r in2 out2 < <(netstat -bI en0 2>/dev/null | awk '$1=="en0" {print $7, $10; exit}')
    BYTES_IN_RATE=$(( in2 - in1 ))
    BYTES_OUT_RATE=$(( out2 - out1 ))
    [ "$BYTES_IN_RATE"  -lt 0 ] && BYTES_IN_RATE=0
    [ "$BYTES_OUT_RATE" -lt 0 ] && BYTES_OUT_RATE=0
}

save_state() {
    # Persist only the slow-changing heavy-check results. Quality
    # metrics (NO_INTERNET, latency, loss, jitter) are NOT cached —
    # they're re-measured every cycle for real-time accuracy.
    # printf %q on KNOWN_NEARBY handles spaces and apostrophes safely.
    {
        printf 'LAST_HEAVY=%s\n'        "$NOW"
        printf 'CAPTIVE_DETECTED=%s\n'  "$CAPTIVE_DETECTED"
        printf 'PORTAL_BLOCKED=%s\n'    "$PORTAL_BLOCKED"
        printf 'KNOWN_NEARBY=%q\n'      "$KNOWN_NEARBY"
        printf 'DNS_BROKEN=%s\n'        "$DNS_BROKEN"
        printf 'HTTPS_BROKEN=%s\n'      "$HTTPS_BROKEN"
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

measure_dns_and_https() {
    # Ping reachability and the HTTP-only captive endpoint can both be
    # fine while DNS or HTTPS are broken — and HTTPS is what actual
    # websites need. This check catches "green dot but Chrome won't
    # load anything" scenarios. We probe multiple domains so a single
    # blocked target doesn't trigger false positives.
    [ "$NO_INTERNET" -eq 1 ] && return
    [ "$PORTAL_BLOCKED" -eq 1 ] && return
    [ "$CAPTIVE_DETECTED" -eq 1 ] && return

    # DNS — try multiple resolvers in case one domain is rate-limited
    # or blocked. First success wins.
    local dns_ok=0
    for d in cloudflare.com google.com apple.com; do
        if host -W 2 "$d" >/dev/null 2>&1; then
            dns_ok=1
            break
        fi
    done
    if [ "$dns_ok" -eq 0 ]; then
        DNS_BROKEN=1
        return  # no point probing HTTPS if DNS is dead
    fi

    # HTTPS — Google's generate_204 returns HTTP 204 with no body and
    # is purpose-built for connectivity checks. If it returns anything
    # else (or curl errors), HTTPS is broken.
    local code
    code=$(curl -sS --max-time 4 -o /dev/null -w "%{http_code}" \
        "https://www.google.com/generate_204" 2>/dev/null)
    if [ "$code" != "204" ]; then
        HTTPS_BROKEN=1
    fi
}

interpret_dns_and_https() {
    if [ "$DNS_BROKEN" -eq 1 ]; then
        RECS+=("DNS lookups failing — pages won't load. Try Reconnect wifi")
        LEVS+=("high")
        ACT_RECONNECT=1
    elif [ "$HTTPS_BROKEN" -eq 1 ]; then
        RECS+=("HTTPS not working — pages won't load. Could be VPN, firewall, or DNS hijack. Try Reconnect wifi")
        LEVS+=("high")
        ACT_RECONNECT=1
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
sample_throughput

# Connection QUALITY (reachability, loss, jitter, latency) is probed
# EVERY cycle — never cached — so the dot reacts within ~10s when a
# path goes choppy mid-call. These outputs are reset then re-measured.
NO_INTERNET=0
LATENCY_AVG=""; LATENCY_JITTER=""; PACKET_LOSS=""
measure_internet_and_latency

# Heavier, slow-changing checks (captive portal, DNS/HTTPS reachability,
# scanning for known networks) stay cached for $HEAVY_INTERVAL.
NOW=$(date +%s)
if (( NOW - LAST_HEAVY > HEAVY_INTERVAL )); then
    CAPTIVE_DETECTED=0; PORTAL_BLOCKED=0
    DNS_BROKEN=0; HTTPS_BROKEN=0
    KNOWN_NEARBY=""

    measure_captive_portal
    measure_dns_and_https
    measure_known_nearby
    save_state
fi

# Interpretations always run, using fresh (quality) or cached (rest) data.
interpret_internet_and_latency
interpret_captive_portal
interpret_dns_and_https
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
elif [ "$DNS_BROKEN" -eq 1 ]; then
    COLOR="#F44336"; LABEL="DNS Broken"; MSG="Pings work but DNS lookups are failing — sites won't load"
elif [ "$HTTPS_BROKEN" -eq 1 ]; then
    COLOR="#F44336"; LABEL="HTTPS Blocked"; MSG="Pings and DNS work but HTTPS fails — sites won't load"
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

# ── Activity levels for the icon ────────────────────────────────────
# Each direction (down, up) gets its own level on a log scale of
# bandwidth. The icon renderer combines them — thin/small arrow for a
# trickle, big/bold for full pipes — so the menu bar communicates both
# direction and intensity at a glance.
#
#  level   threshold (bytes/sec)
#   none   < 10K   (arrow hidden)
#    0     10K  – 50K
#    1     50K  – 500K
#    2     500K – 5M
#    3     5M   – 50M
#    4     50M  – 500M
#    5     500M +
rate_to_level() {
    local r="$1"
    if   [ "$r" -ge 524288000 ]; then echo "5"
    elif [ "$r" -ge  52428800 ]; then echo "4"
    elif [ "$r" -ge   5242880 ]; then echo "3"
    elif [ "$r" -ge    524288 ]; then echo "2"
    elif [ "$r" -ge     51200 ]; then echo "1"
    elif [ "$r" -ge     10240 ]; then echo "0"
    else                              echo "none"
    fi
}

DOWN_LEVEL=$(rate_to_level "$BYTES_IN_RATE")
UP_LEVEL=$(rate_to_level "$BYTES_OUT_RATE")

# ── Render ──────────────────────────────────────────────────────────
# Single menu bar item, rendered as an image so the colored dot and
# gray arrow can share one slot tucked tight together.
SSID_DISPLAY="$SSID"
[ "$IS_HOTSPOT" -eq 1 ] && SSID_DISPLAY="$SSID (hotspot)"

COLOR_HEX="${COLOR#\#}"
ICON_FILE="$ICONS_DIR/${COLOR_HEX}-d${DOWN_LEVEL}-u${UP_LEVEL}.b64"
# Lazy cache: render on first encounter, then reuse forever.
if [ ! -r "$ICON_FILE" ]; then
    mkdir -p "$ICONS_DIR"
    if [ -x "$HELPER_DIR/gen-icon" ]; then
        "$HELPER_DIR/gen-icon" "$COLOR_HEX" "$DOWN_LEVEL" "$UP_LEVEL" \
            > "$ICON_FILE" 2>/dev/null
    fi
fi
if [ -r "$ICON_FILE" ] && [ -s "$ICON_FILE" ]; then
    echo " | image=$(cat "$ICON_FILE")"
else
    # Fallback — gen-icon missing or failed.
    echo "● | size=14 color=$COLOR"
fi
echo "---"
echo "$SSID_DISPLAY — $LABEL | size=14"
echo "$MSG | size=11 color=#888888"

# Actionable recommendations + one-click fixes stay at the top level —
# they only appear when there's actually something to act on.
if [ ${#RECS[@]} -gt 0 ]; then
    echo "---"
    for i in "${!RECS[@]}"; do
        if [ "${LEVS[$i]}" = "high" ]; then
            echo "⚡ ${RECS[$i]} | color=#F44336 size=12"
        else
            echo "→ ${RECS[$i]} | color=#FF9800 size=12"
        fi
    done
    [ "$ACT_PORTAL" -eq 1 ] && echo "🔓 Open login page | shell=\"$ACTIONS\" param1=portal terminal=false size=12"
    [ -n "$ACT_SWITCH" ] && echo "📶 Switch to $ACT_SWITCH | shell=\"$ACTIONS\" param1=switch param2=\"$ACT_SWITCH\" terminal=false refresh=true size=12"
    [ "$ACT_RECONNECT" -eq 1 ] && echo "🔄 Reconnect wifi | shell=\"$ACTIONS\" param1=reconnect terminal=false refresh=true size=12"
fi

echo "---"

# ── Details — raw metrics, collapsed into a submenu ─────────────────
RATE_IN=$(format_rate "$BYTES_IN_RATE")
RATE_OUT=$(format_rate "$BYTES_OUT_RATE")
echo "Details | size=12"
echo "-- ↓ Down:      ${RATE_IN}/s | font=Menlo size=12"
echo "-- ↑ Up:        ${RATE_OUT}/s | font=Menlo size=12"
if [ -n "$LATENCY_AVG" ]; then
    echo "-- Latency:     ${LATENCY_AVG} ms (±${LATENCY_JITTER}) | font=Menlo size=12"
    echo "-- Loss:        ${PACKET_LOSS}% | font=Menlo size=12"
fi
echo "-- Signal:      ${RSSI} dBm | font=Menlo size=12"
echo "-- Noise:       ${NOISE} dBm | font=Menlo size=12"
echo "-- SNR:         ${SNR} dB | font=Menlo size=12"
echo "-- Channel:     ${CHANNEL} ($BAND) | font=Menlo size=12"
echo "-- Link Speed:  ${TX_RATE} Mbps | font=Menlo size=12"

# ── Advanced view — pops out the rich widget (live detail + the
#    call-quality diagnosis with a Run button that actually works). ───
echo "Advanced & call quality… | shell=\"$ACTIONS\" param1=dashboard terminal=false size=12"

# ── More — tools, collapsed into a submenu ──────────────────────────
echo "More | size=12"
echo "-- Run speed test… | shell=\"$ACTIONS\" param1=speed-test terminal=false size=12"
echo "-- Wi-Fi settings… | shell=\"$ACTIONS\" param1=settings terminal=false size=12"
echo "-- Re-check connectivity now | shell=\"$ACTIONS\" param1=recheck terminal=false refresh=true size=12"
echo "-- Refresh | refresh=true size=12"
