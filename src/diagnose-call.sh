#!/bin/bash
# diagnose-call.sh — localize a real-time call-quality problem.
#
# A choppy video call can be caused by your wifi/local link, your ISP
# path, your link being saturated (bufferbloat), or the far end (the
# other participant or the conferencing server). We can't see the other
# person's connection, but we CAN measure and decompose YOUR path to
# rule your side in or out.
#
# Probes, comparing where loss/jitter is introduced:
#   1. gateway  — your wifi link + router (purely local)
#   2. 1.1.1.1  — full path to the internet (Cloudflare)
#   3. 8.8.8.8  — path toward Google (proxy for Meet/Hangouts servers)
#   4. bufferbloat — does latency balloon when the link is loaded?
#
# Then prints a verdict: is the problem your side, or not?

bold=$'\033[1m'; dim=$'\033[2m'; grn=$'\033[32m'; ylw=$'\033[33m'
red=$'\033[31m'; cyn=$'\033[36m'; rst=$'\033[0m'

GW=$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}')

echo "${bold}${cyn}wifi-health · call quality diagnosis${rst}"
echo "${dim}Measuring your path — ~25s. Watch for where loss/jitter appears.${rst}"
echo

# probe <label> <target> — 25 pings (~5s). Echoes a status line and
# sets globals LOSS, JITTER, AVG for the verdict logic.
probe() {
    local label="$1" target="$2" out
    LOSS=100; JITTER=0; AVG=0
    [ -z "$target" ] && { printf "  %-26s %s\n" "$label" "${dim}(unavailable)${rst}"; return; }
    out=$(ping -c 25 -i 0.2 -W 1 "$target" 2>/dev/null)
    if ! echo "$out" | grep -q "packets transmitted"; then
        printf "  %s%-5s%s%-22s %sno response%s\n" "$red" "BAD" "$rst" "$label" "$red" "$rst"
        return
    fi
    LOSS=$(echo "$out" | awk -F'[%]' '/packet loss/{print $1}' | awk '{print $NF}'); LOSS=${LOSS%.*}
    local stats; stats=$(echo "$out" | grep -E 'min/avg/max')
    AVG=$(echo "$stats"    | awk -F'=' '{print $2}' | awk -F'/' '{print $2}' | cut -d. -f1)
    JITTER=$(echo "$stats" | awk -F'=' '{print $2}' | awk -F'/' '{print $4}' | cut -d. -f1)
    AVG=${AVG:-0}; JITTER=${JITTER:-0}

    # Tag the line by real-time-media suitability. ASCII tags render in
    # any terminal/font (the ● glyph showed as ?? in some fonts).
    local tag col
    if [ "$LOSS" -gt 2 ] 2>/dev/null || [ "$JITTER" -gt 30 ] 2>/dev/null; then
        tag="BAD";  col="$red"
    elif [ "$LOSS" -gt 0 ] 2>/dev/null || [ "$JITTER" -gt 15 ] 2>/dev/null; then
        tag="WARN"; col="$ylw"
    else
        tag="OK";   col="$grn"
    fi
    printf "  %s%-5s%s%-22s loss %3s%%   avg %4sms   jitter ±%sms\n" \
        "$col" "$tag" "$rst" "$label" "$LOSS" "$AVG" "$JITTER"
}

echo "${bold}Path quality${rst}  ${dim}(OK · WARN · BAD for real-time calls)${rst}"
probe "Your router (local)" "$GW";   GW_LOSS=$LOSS;  GW_JIT=$JITTER
probe "Internet (Cloudflare)" "1.1.1.1"; CF_LOSS=$LOSS; CF_JIT=$JITTER
probe "Google (Meet path)" "8.8.8.8";    GG_LOSS=$LOSS; GG_JIT=$JITTER

# ── Bufferbloat: latency idle vs under download load ────────────────
echo
echo "${bold}Bufferbloat${rst}  ${dim}(latency rise when the link is busy — kills calls)${rst}"
base=$(ping -c 5 -i 0.2 -W 1 1.1.1.1 2>/dev/null | grep -E 'min/avg/max' | awk -F'/' '{print $5}' | cut -d. -f1)
base=${base:-0}
# Saturate download for a few seconds while measuring latency.
curl -s --max-time 6 "https://speed.cloudflare.com/__down?bytes=50000000" -o /dev/null 2>/dev/null &
LOADPID=$!
sleep 1
loaded=$(ping -c 12 -i 0.2 -W 1 1.1.1.1 2>/dev/null | grep -E 'min/avg/max' | awk -F'/' '{print $5}' | cut -d. -f1)
loaded=${loaded:-0}
wait "$LOADPID" 2>/dev/null
BLOAT=$(( loaded - base ))
[ "$BLOAT" -lt 0 ] && BLOAT=0
btag="OK";  bcol="$grn"
if   [ "$BLOAT" -gt 100 ] 2>/dev/null; then btag="BAD";  bcol="$red"
elif [ "$BLOAT" -gt 40  ] 2>/dev/null; then btag="WARN"; bcol="$ylw"; fi
printf "  %s%-5s%sidle %sms -> loaded %sms   (+%sms under load)\n" \
    "$bcol" "$btag" "$rst" "$base" "$loaded" "$BLOAT"

# ── Verdict ─────────────────────────────────────────────────────────
echo
echo "${bold}Verdict${rst}"

local_bad=0;  [ "${GW_LOSS:-0}" -gt 1 ] 2>/dev/null && local_bad=1
[ "${GW_JIT:-0}" -gt 20 ] 2>/dev/null && local_bad=1
remote_bad=0
[ "${CF_LOSS:-0}" -gt 2 ] 2>/dev/null && remote_bad=1
[ "${CF_JIT:-0}" -gt 30 ] 2>/dev/null && remote_bad=1
[ "${GG_LOSS:-0}" -gt 2 ] 2>/dev/null && remote_bad=1
[ "${GG_JIT:-0}" -gt 30 ] 2>/dev/null && remote_bad=1
bloat_bad=0;  [ "$BLOAT" -gt 100 ] 2>/dev/null && bloat_bad=1

if [ "$local_bad" -eq 1 ]; then
    echo "  ${red}> It's YOUR local link (wifi / router).${rst}"
    echo "    Loss or jitter is appearing on the very first hop, so the"
    echo "    problem is between your Mac and your router."
    echo "    Try: move closer to the router · switch to 5GHz · reduce"
    echo "    interference (microwaves, neighbors) · reconnect wifi."
elif [ "$bloat_bad" -eq 1 ]; then
    echo "  ${red}> Bufferbloat — your link is being saturated.${rst}"
    echo "    Latency jumps +${BLOAT}ms when busy, which makes calls stutter."
    echo "    Something is using your bandwidth (check the menu bar arrows)."
    echo "    Try: pause big downloads/uploads, cloud sync, or backups."
elif [ "$remote_bad" -eq 1 ]; then
    echo "  ${ylw}> Your ISP / upstream path is degraded.${rst}"
    echo "    Your local link is clean but loss/jitter appears further out."
    echo "    Less in your control. Try: reconnect wifi; if it persists"
    echo "    across calls, it may be worth contacting your ISP."
else
    echo "  ${grn}> Your side looks clean.${rst}"
    echo "    Low loss, low jitter, no bufferbloat all the way out. The"
    echo "    choppiness was most likely the OTHER participant's connection"
    echo "    or the call server — not something you can fix on your end."
fi
echo
echo "${dim}Done — close this window when you're finished (Cmd-W).${rst}"
