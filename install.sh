#!/bin/bash
set -e

BOLD="\033[1m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

PLUGIN_DIR="$HOME/Library/Application Support/SwiftBar/Plugins"
HELPER_DIR="$HOME/Library/Application Support/SwiftBar"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

info()  { echo -e "${BOLD}${GREEN}▸${RESET} $1"; }
warn()  { echo -e "${BOLD}${YELLOW}▸${RESET} $1"; }
fail()  { echo -e "${BOLD}${RED}✗${RESET} $1"; exit 1; }

# ── Prerequisites ───────────────────────────────────────────────────
command -v brew >/dev/null 2>&1 || fail "Homebrew is required. Install from https://brew.sh"
command -v swiftc >/dev/null 2>&1 || fail "Xcode Command Line Tools required: xcode-select --install"

# ── SwiftBar ────────────────────────────────────────────────────────
if ! ls /Applications/SwiftBar.app >/dev/null 2>&1; then
    info "Installing SwiftBar…"
    brew install --cask swiftbar
else
    info "SwiftBar already installed"
fi

# ── Compile Swift helpers ───────────────────────────────────────────
info "Compiling wifi-info helper…"
mkdir -p "$HELPER_DIR"
swiftc -O -o "$HELPER_DIR/wifi-info" "$SCRIPT_DIR/src/wifi-info.swift"
info "Binary → $HELPER_DIR/wifi-info"

info "Compiling gen-icon helper…"
swiftc -O -o "$HELPER_DIR/gen-icon" "$SCRIPT_DIR/src/gen-icon.swift"
info "Binary → $HELPER_DIR/gen-icon"

# ── Pre-generate menu bar icons ─────────────────────────────────────
# 3 health colors × 4 activity states = 12 base64 PNGs cached on disk
# so the plugin script doesn't have to invoke Swift on every refresh.
info "Generating menu bar icons…"
ICONS_DIR="$HELPER_DIR/icons"
mkdir -p "$ICONS_DIR"
for color in 4CAF50 FF9800 F44336; do
    for state in none down up both; do
        "$HELPER_DIR/gen-icon" "$color" "$state" > "$ICONS_DIR/${color}-${state}.b64"
    done
done
info "Icons → $ICONS_DIR"

# ── Install actions helper ──────────────────────────────────────────
info "Installing wifi-actions helper…"
cp "$SCRIPT_DIR/src/wifi-actions.sh" "$HELPER_DIR/wifi-actions.sh"
chmod +x "$HELPER_DIR/wifi-actions.sh"
info "Actions → $HELPER_DIR/wifi-actions.sh"

# ── Install plugin ──────────────────────────────────────────────────
info "Installing SwiftBar plugin…"
mkdir -p "$PLUGIN_DIR"
# Clean up older filenames from previous versions (filename encodes
# refresh interval, so renames leave orphans).
rm -f "$PLUGIN_DIR/wifi-health.5m.sh" "$PLUGIN_DIR/wifi-health.1m.sh"
rm -f "$PLUGIN_DIR/wifi-activity.5s.sh"  # merged into wifi-health

cp "$SCRIPT_DIR/src/wifi-health.10s.sh" "$PLUGIN_DIR/wifi-health.10s.sh"
chmod +x "$PLUGIN_DIR/wifi-health.10s.sh"
info "Plugin → $PLUGIN_DIR/wifi-health.10s.sh"

# ── Set SwiftBar plugin directory ───────────────────────────────────
defaults write com.ameba.SwiftBar PluginDirectory "$PLUGIN_DIR"

# ── Launch SwiftBar ─────────────────────────────────────────────────
if ! pgrep -x SwiftBar >/dev/null 2>&1; then
    info "Launching SwiftBar…"
    open -a SwiftBar
else
    info "SwiftBar is running — refreshing plugins…"
    osascript -e 'tell application "SwiftBar" to activate' 2>/dev/null || true
fi

echo ""
info "Done! Look for the colored ● in your menu bar."
echo "  Green  = connection is solid"
echo "  Yellow = room for improvement or limited options"
echo "  Red    = attention needed, clear fixes available"
echo ""
echo "Click the dot for details and recommendations."
