#!/bin/bash
# simulate.sh — render the menu bar icon across a wide range of
# synthetic (down, up) bandwidth scenarios and tile them into a single
# HTML page so we can compare the variants visually.
#
# Run after install.sh. Writes /tmp/wifi-health-simulation.html and
# opens it in the default browser.

set -e

HELPER_DIR="$HOME/Library/Application Support/SwiftBar"
GEN="$HELPER_DIR/gen-icon"

if [ ! -x "$GEN" ]; then
    # Allow running before install — compile a temp binary.
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    GEN=/tmp/gen-icon
    echo "Compiling $GEN from src/gen-icon.swift…"
    swiftc -O -o "$GEN" "$SCRIPT_DIR/src/gen-icon.swift"
fi

# Same mapping as the plugin. Keep in sync with rate_to_level in
# wifi-health.10s.sh.
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

# Format a byte/sec value as a human string.
fmt_rate() {
    awk -v b="$1" 'BEGIN {
        if (b == 0)               printf "0"
        else if (b < 1024)        printf "%dB/s", b
        else if (b < 1048576)     printf "%dK/s", b/1024 + 0.5
        else if (b < 1073741824)  printf "%.1fM/s", b/1048576
        else                      printf "%.1fG/s", b/1073741824
    }'
}

# Test cases — (label, down, up) tuples. Sweep through orders of
# magnitude individually, then mixed scenarios.
declare -a CASES
CASES+=("idle|0|0")
# Down-only sweep
for r in 0 30000 200000 2000000 20000000 200000000 1000000000; do
    [ "$r" -gt 0 ] && CASES+=("down only|$r|0")
done
# Up-only sweep
for r in 30000 200000 2000000 20000000 200000000 1000000000; do
    CASES+=("up only|0|$r")
done
# Symmetric
for r in 30000 200000 2000000 20000000 200000000; do
    CASES+=("symmetric|$r|$r")
done
# Asymmetric scenarios
CASES+=("download + small upload|10000000|100000")
CASES+=("upload + small download|100000|10000000")
CASES+=("big down + medium up|100000000|500000")
CASES+=("balanced fast|50000000|50000000")
CASES+=("WAN saturate|500000000|10000000")

HTML=/tmp/wifi-health-simulation.html

cat > "$HTML" <<'HEAD'
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>wifi-health icon simulation</title>
<style>
  body { font-family: -apple-system, sans-serif; background: #fafafa; color: #333; padding: 24px; }
  h1 { font-weight: 500; }
  table { border-collapse: collapse; margin-top: 16px; }
  td { padding: 8px 14px; vertical-align: middle; }
  tr:nth-child(even) td { background: #f0f0f0; }
  tr:nth-child(odd)  td { background: #fff; }
  .icon { background: #e8e8e8; padding: 4px 8px; border-radius: 6px; }
  .icon img { display: block; image-rendering: pixelated; height: 28px; }
  .icon-dark { background: #2a2a2a; }
  .levels { color: #888; font-family: ui-monospace, monospace; font-size: 12px; }
  .rate { font-family: ui-monospace, monospace; }
  .label { color: #666; font-size: 13px; }
  th { text-align: left; padding: 8px 14px; font-weight: 500; color: #666; border-bottom: 1px solid #ddd; }
</style></head><body>
<h1>wifi-health menu bar — simulation</h1>
<p class="label">Each row: dot color • down rate • up rate • computed levels • icon (light bg) • icon (dark bg)</p>
<table>
<tr><th>Scenario</th><th>↓ rate</th><th>↑ rate</th><th>levels</th><th>green</th><th>yellow</th><th>red</th><th>dark mode</th></tr>
HEAD

for entry in "${CASES[@]}"; do
    IFS='|' read -r LABEL DOWN UP <<< "$entry"
    DL=$(rate_to_level "$DOWN")
    UL=$(rate_to_level "$UP")
    DR=$(fmt_rate "$DOWN")
    UR=$(fmt_rate "$UP")

    GREEN_B64=$("$GEN"  4CAF50 "$DL" "$UL")
    YELLOW_B64=$("$GEN" FF9800 "$DL" "$UL")
    RED_B64=$("$GEN"    F44336 "$DL" "$UL")

    cat >> "$HTML" <<ROW
<tr>
  <td class="label">$LABEL</td>
  <td class="rate">$DR</td>
  <td class="rate">$UR</td>
  <td class="levels">d=$DL u=$UL</td>
  <td><span class="icon"><img src="data:image/png;base64,$GREEN_B64"></span></td>
  <td><span class="icon"><img src="data:image/png;base64,$YELLOW_B64"></span></td>
  <td><span class="icon"><img src="data:image/png;base64,$RED_B64"></span></td>
  <td><span class="icon icon-dark"><img src="data:image/png;base64,$GREEN_B64"></span></td>
</tr>
ROW
done

cat >> "$HTML" <<'TAIL'
</table>
</body></html>
TAIL

echo "Wrote $HTML — opening in browser…"
open "$HTML"
