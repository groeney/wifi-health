#!/bin/bash
# wifi-activity.5s.sh — companion SwiftBar plugin to wifi-health.
# Shows a subtle gray arrow next to the menu bar when there's notable
# network traffic. Sits as its own item so the health dot keeps its
# color and this stays a quiet ambient indicator.

# Threshold for showing an arrow: ignore background chatter (DNS,
# keepalives, etc.). 10 KB/s in a direction is "something is happening."
THRESHOLD=10240

# ── Sample byte counters ────────────────────────────────────────────
# netstat -bI columns: Name Mtu Net Addr Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll
read -r in1 out1 < <(netstat -bI en0 2>/dev/null | awk '$1=="en0" {print $7, $10; exit}')
sleep 1
read -r in2 out2 < <(netstat -bI en0 2>/dev/null | awk '$1=="en0" {print $7, $10; exit}')

if [ -z "$in1" ] || [ -z "$in2" ]; then
    # Interface missing — render nothing visible.
    echo "· | size=10 color=#888888"
    echo "---"
    echo "WiFi off or interface missing"
    exit 0
fi

IN_RATE=$(( in2 - in1 ))
OUT_RATE=$(( out2 - out1 ))
[ "$IN_RATE"  -lt 0 ] && IN_RATE=0
[ "$OUT_RATE" -lt 0 ] && OUT_RATE=0

# ── Format helper ───────────────────────────────────────────────────
format_rate() {
    awk -v b="$1" 'BEGIN {
        if (b < 1024)             printf "%dB", b
        else if (b < 1048576)     printf "%dK", b/1024 + 0.5
        else if (b < 1073741824)  printf "%.1fM", b/1048576
        else                      printf "%.1fG", b/1073741824
    }'
}

# ── Pick the glyph ──────────────────────────────────────────────────
# When idle, show a tiny middle dot — confirms the meter is alive
# without adding visual noise.
ACT_IN=0
ACT_OUT=0
[ "$IN_RATE"  -gt "$THRESHOLD" ] && ACT_IN=1
[ "$OUT_RATE" -gt "$THRESHOLD" ] && ACT_OUT=1

if [ "$ACT_IN" -eq 1 ] && [ "$ACT_OUT" -eq 1 ]; then
    GLYPH="⇅"
elif [ "$ACT_IN" -eq 1 ]; then
    GLYPH="↓"
elif [ "$ACT_OUT" -eq 1 ]; then
    GLYPH="↑"
else
    GLYPH="·"
fi

# ── Render ──────────────────────────────────────────────────────────
# Smaller font and a muted gray keep this strictly FYI. Sits next to
# the wifi-health dot in the menu bar.
echo "$GLYPH | size=11 color=#888888"
echo "---"
echo "Network activity | size=11 color=#888888"
echo "---"
RATE_IN=$(format_rate "$IN_RATE")
RATE_OUT=$(format_rate "$OUT_RATE")
echo "↓ Down:  ${RATE_IN}/s | font=Menlo size=12"
echo "↑ Up:    ${RATE_OUT}/s | font=Menlo size=12"
echo "---"
echo "Refresh | refresh=true size=11 color=#888888"
