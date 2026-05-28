#!/bin/bash
# traffic-sim.sh — generate REAL network traffic at stepped rates so you
# can watch the wifi-health menu bar arrows respond live.
#
# Downloads from and uploads to Cloudflare's public speed-test endpoints
# (speed.cloudflare.com). Every downloaded byte goes straight to
# /dev/null; every uploaded byte is a throwaway buffer of zeros that
# Cloudflare discards. Nothing of consequence touches your disk.
#
# The widget refreshes ~every 10s and samples ~1s of traffic, so each
# stage is held ~20s to be sure it's observed. Watch the colored dot —
# the ↓ and ↑ arrows should grow bigger and bolder as the rate climbs.
#
# Heads up: this moves real data. A full run can transfer a few GB on a
# fast link. Ctrl-C any time to stop; cleanup is automatic.
#
# Usage:  bash traffic-sim.sh
#         HOLD=30 bash traffic-sim.sh     # hold each stage 30s
#         bash traffic-sim.sh down        # only the download ladder
#         bash traffic-sim.sh up          # only the upload ladder
#         bash traffic-sim.sh both        # only the combined stages

set -u

DOWN_URL="https://speed.cloudflare.com/__down?bytes=50000000000"
UP_URL="https://speed.cloudflare.com/__up"
HOLD="${HOLD:-20}"
SCRATCH="$(mktemp -t wifihealthsim.XXXXXX)"
WHICH="${1:-all}"

command -v curl >/dev/null 2>&1 || { echo "curl is required." >&2; exit 1; }

cleanup() {
    echo
    echo "Stopping and cleaning up…"
    # Kill only the curls this script started (matched by the CF URLs),
    # so we never touch unrelated processes.
    pkill -f "speed.cloudflare.com/__down" 2>/dev/null
    pkill -f "speed.cloudflare.com/__up"   2>/dev/null
    rm -f "$SCRATCH"
    exit 0
}
trap cleanup INT TERM

echo "Building 64 MB upload buffer…"
dd if=/dev/zero of="$SCRATCH" bs=1048576 count=64 2>/dev/null

# run_down <rate|max> — one capped GET that fills the hold window.
run_down() {
    local lim=()
    [ "$1" != "max" ] && lim=(--limit-rate "$1")
    curl -s --max-time "$HOLD" "${lim[@]}" "$DOWN_URL" -o /dev/null 2>/dev/null || true
}

# run_up <rate|max> — POST the buffer, looping until the hold window ends
# (a single buffer can drain before HOLD at higher rates).
run_up() {
    local lim=() end remaining
    [ "$1" != "max" ] && lim=(--limit-rate "$1")
    end=$(( $(date +%s) + HOLD ))
    while remaining=$(( end - $(date +%s) )); [ "$remaining" -gt 0 ]; do
        curl -s --max-time "$remaining" "${lim[@]}" \
            -X POST --data-binary @"$SCRATCH" "$UP_URL" -o /dev/null 2>/dev/null || true
    done
}

banner() {
    echo
    echo "────────────────────────────────────────────────────"
    echo "▶ $1"
    echo "  holding ${HOLD}s — watch the menu bar dot's arrows"
    echo "────────────────────────────────────────────────────"
}

echo
echo "=== wifi-health LIVE traffic simulation ==="
echo "Real traffic via Cloudflare; everything discarded. Ctrl-C to stop."
echo "Levels:  L0 10–50K · L1 50–500K · L2 500K–5M · L3 5–50M · L4 50–500M · L5 500M+"

do_down() {
    banner "↓ DOWNLOAD ~30 KB/s     → ↓ thin    (L0)"; run_down 30k
    banner "↓ DOWNLOAD ~300 KB/s    → ↓ light   (L1)"; run_down 300k
    banner "↓ DOWNLOAD ~3 MB/s      → ↓ regular (L2)"; run_down 3m
    banner "↓ DOWNLOAD ~30 MB/s     → ↓ medium  (L3, link permitting)"; run_down 30m
    banner "↓ DOWNLOAD max          → as fast as your link goes"; run_down max
}

do_up() {
    banner "↑ UPLOAD ~30 KB/s       → ↑ thin    (L0)"; run_up 30k
    banner "↑ UPLOAD ~300 KB/s      → ↑ light   (L1)"; run_up 300k
    banner "↑ UPLOAD ~3 MB/s        → ↑ regular (L2)"; run_up 3m
    banner "↑ UPLOAD max            → as fast as your link goes"; run_up max
}

do_both() {
    banner "↓↑ BOTH ~3 MB/s each    → ↓ and ↑ side by side, equal weight"
    run_down 3m & run_up 3m & wait
    banner "↓↑ BOTH max             → saturate both directions"
    run_down max & run_up max & wait
}

case "$WHICH" in
    down) do_down ;;
    up)   do_up ;;
    both) do_both ;;
    all)  do_down; do_up; do_both ;;
    *)    echo "unknown stage '$WHICH' (use: down | up | both | all)"; cleanup ;;
esac

echo
echo "Simulation complete."
cleanup
