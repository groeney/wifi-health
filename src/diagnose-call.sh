#!/bin/bash
# diagnose-call.sh — localize a real-time call-quality problem.
#
# A choppy video call can be caused by your wifi/local link, your ISP
# path, your link being saturated (bufferbloat), or the far end (the
# other participant or the conferencing server). We can't see the other
# person's connection, but we CAN measure and decompose YOUR path to
# rule your side in or out.
#
# Probes (comparing where loss/jitter appears):
#   1. gateway  — your wifi link + router (purely local)
#   2. 1.1.1.1  — full path to the internet (Cloudflare)
#   3. 8.8.8.8  — path toward Google (proxy for Meet/Hangouts servers)
#   4. bufferbloat — does latency balloon when the link is loaded?
#
# Modes:
#   (no args)   print a human-readable report to the terminal
#   --widget    write structured results to the SwiftBar result file
#               (no stdout) so the menu bar dropdown can display them

HELPER_DIR="$HOME/Library/Application Support/SwiftBar"
RESULT="$HELPER_DIR/diagnose.result"
MODE="${1:-terminal}"
PKTS=20

GW=$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}')

# ── Measurement ─────────────────────────────────────────────────────
# classify <loss%> <jitterms> → OK | WARN | BAD (real-time-media bias)
classify() {
    local loss="${1:-100}" jit="${2:-0}"
    if   [ "$loss" -gt 5  ] 2>/dev/null || [ "$jit" -gt 30 ] 2>/dev/null; then echo BAD
    elif [ "$loss" -gt 0  ] 2>/dev/null || [ "$jit" -gt 15 ] 2>/dev/null; then echo WARN
    else echo OK; fi
}

# probe <target> → echoes "TAG LOSS AVG JIT"
probe() {
    local target="$1" out loss avg jit stats
    [ -z "$target" ] && { echo "NA - - -"; return; }
    out=$(ping -c "$PKTS" -i 0.2 -W 1 "$target" 2>/dev/null)
    if ! echo "$out" | grep -q "packets transmitted"; then
        echo "BAD 100 - -"; return
    fi
    loss=$(echo "$out" | awk -F'[%]' '/packet loss/{print $1}' | awk '{print $NF}'); loss=${loss%.*}; loss=${loss:-0}
    stats=$(echo "$out" | grep -E 'min/avg/max')
    avg=$(echo "$stats" | awk -F'=' '{print $2}' | awk -F'/' '{print $2}' | cut -d. -f1); avg=${avg:-0}
    jit=$(echo "$stats" | awk -F'=' '{print $2}' | awk -F'/' '{print $4}' | cut -d. -f1); jit=${jit:-0}
    echo "$(classify "$loss" "$jit") $loss $avg $jit"
}

read -r RTR_TAG RTR_LOSS RTR_AVG RTR_JIT <<< "$(probe "$GW")"
read -r CF_TAG  CF_LOSS  CF_AVG  CF_JIT  <<< "$(probe 1.1.1.1)"
read -r GG_TAG  GG_LOSS  GG_AVG  GG_JIT  <<< "$(probe 8.8.8.8)"

# Bufferbloat: idle vs under-download latency.
BASE=$(ping -c 5 -i 0.2 -W 1 1.1.1.1 2>/dev/null | grep -E 'min/avg/max' | awk -F'/' '{print $5}' | cut -d. -f1); BASE=${BASE:-0}
curl -s --max-time 4 "https://speed.cloudflare.com/__down?bytes=50000000" -o /dev/null 2>/dev/null &
LP=$!
sleep 1
LOADED=$(ping -c 10 -i 0.2 -W 1 1.1.1.1 2>/dev/null | grep -E 'min/avg/max' | awk -F'/' '{print $5}' | cut -d. -f1); LOADED=${LOADED:-0}
wait "$LP" 2>/dev/null
BLOAT=$(( LOADED - BASE )); [ "$BLOAT" -lt 0 ] && BLOAT=0
if   [ "$BLOAT" -gt 100 ]; then BLOAT_TAG=BAD
elif [ "$BLOAT" -gt 40  ]; then BLOAT_TAG=WARN
else BLOAT_TAG=OK; fi

# Verdict.
local_bad=0
[ "${RTR_LOSS:-0}" -gt 0  ] 2>/dev/null && local_bad=1
[ "${RTR_JIT:-0}"  -gt 20 ] 2>/dev/null && local_bad=1
remote_bad=0
[ "${CF_LOSS:-0}" -gt 5 ] 2>/dev/null && remote_bad=1
[ "${CF_JIT:-0}" -gt 30 ] 2>/dev/null && remote_bad=1
[ "${GG_LOSS:-0}" -gt 5 ] 2>/dev/null && remote_bad=1
[ "${GG_JIT:-0}" -gt 30 ] 2>/dev/null && remote_bad=1
if   [ "$local_bad"  -eq 1 ]; then VERDICT=local
elif [ "$BLOAT" -gt 100 ];    then VERDICT=bloat
elif [ "$remote_bad" -eq 1 ]; then VERDICT=remote
else VERDICT=clean; fi

# ── Output ──────────────────────────────────────────────────────────
if [ "$MODE" = "--widget" ]; then
    tmp="$RESULT.tmp.$$"
    {
        echo "DIAG_STATUS=done"
        echo "DIAG_END=$(date +%s)"
        echo "DIAG_RTR=\"$RTR_TAG $RTR_LOSS $RTR_AVG $RTR_JIT\""
        echo "DIAG_CF=\"$CF_TAG $CF_LOSS $CF_AVG $CF_JIT\""
        echo "DIAG_GG=\"$GG_TAG $GG_LOSS $GG_AVG $GG_JIT\""
        echo "DIAG_BLOAT=\"$BLOAT_TAG $BASE $LOADED $BLOAT\""
        echo "DIAG_VERDICT=$VERDICT"
    } > "$tmp"
    mv -f "$tmp" "$RESULT"
    exit 0
fi

# Terminal report.
bold=$'\033[1m'; dim=$'\033[2m'; grn=$'\033[32m'; ylw=$'\033[33m'
red=$'\033[31m'; cyn=$'\033[36m'; rst=$'\033[0m'
color_for() { case "$1" in OK) printf '%s' "$grn";; WARN) printf '%s' "$ylw";; BAD) printf '%s' "$red";; *) printf '%s' "$dim";; esac; }
line() { # line <tag> <label> <loss> <avg> <jit>
    printf "  %s%-5s%s%-22s loss %3s%%   avg %4sms   jitter ±%sms\n" \
        "$(color_for "$1")" "$1" "$rst" "$2" "$3" "$4" "$5"
}

echo "${bold}${cyn}wifi-health · call quality diagnosis${rst}"
echo "${bold}Path quality${rst}  ${dim}(OK · WARN · BAD for real-time calls)${rst}"
line "$RTR_TAG" "Your router (local)"   "$RTR_LOSS" "$RTR_AVG" "$RTR_JIT"
line "$CF_TAG"  "Internet (Cloudflare)" "$CF_LOSS"  "$CF_AVG"  "$CF_JIT"
line "$GG_TAG"  "Google (Meet path)"    "$GG_LOSS"  "$GG_AVG"  "$GG_JIT"
echo
echo "${bold}Bufferbloat${rst}  ${dim}(latency rise when the link is busy)${rst}"
printf "  %s%-5s%sidle %sms -> loaded %sms   (+%sms under load)\n" \
    "$(color_for "$BLOAT_TAG")" "$BLOAT_TAG" "$rst" "$BASE" "$LOADED" "$BLOAT"
echo
echo "${bold}Verdict${rst}"
case "$VERDICT" in
    local)  echo "  ${red}> It's YOUR local link (wifi / router).${rst}"
            echo "    Try: move closer · 5GHz · reduce interference · reconnect." ;;
    bloat)  echo "  ${red}> Bufferbloat — your link is saturated (+${BLOAT}ms under load).${rst}"
            echo "    Pause big downloads/uploads, cloud sync, or backups." ;;
    remote) echo "  ${ylw}> Your ISP / upstream path is degraded.${rst}"
            echo "    Local link is clean; loss/jitter appears further out." ;;
    *)      echo "  ${grn}> Your side looks clean.${rst}"
            echo "    Likely the other participant or the call server — not you." ;;
esac
echo
echo "${dim}Done — close this window when finished (Cmd-W).${rst}"
