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

# ── Build the advanced pop-out app ──────────────────────────────────
# A native AppKit/SwiftUI window (live metrics + call-quality check).
# Assembled into a .app bundle so the menu can launch it with `open`,
# fully detached from SwiftBar. Compiled locally — no notarization.
info "Building advanced dashboard app…"
APP="$HELPER_DIR/WifiHealth.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/WifiHealth" "$SCRIPT_DIR/src/dashboard.swift"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>WiFi Health</string>
  <key>CFBundleDisplayName</key><string>WiFi Health</string>
  <key>CFBundleIdentifier</key><string>com.groeney.wifihealth.dashboard</string>
  <key>CFBundleExecutable</key><string>WifiHealth</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
info "Dashboard → $APP"

# ── Icons cache ─────────────────────────────────────────────────────
# The plugin renders icons on-demand via gen-icon and caches them in
# this directory keyed by (color, down-level, up-level). Clear stale
# icons from older formats; the plugin will regenerate as needed.
ICONS_DIR="$HELPER_DIR/icons"
info "Resetting icon cache…"
rm -rf "$ICONS_DIR"
mkdir -p "$ICONS_DIR"
# Drop any stale state/result files from previous versions.
rm -f "$HELPER_DIR/diagnose.result"
info "Cache → $ICONS_DIR"

# ── Install helper scripts ──────────────────────────────────────────
info "Installing helper scripts…"
cp "$SCRIPT_DIR/src/wifi-actions.sh"  "$HELPER_DIR/wifi-actions.sh"
cp "$SCRIPT_DIR/src/diagnose-call.sh" "$HELPER_DIR/diagnose-call.sh"
cp "$SCRIPT_DIR/src/wifi-update.sh"   "$HELPER_DIR/wifi-update.sh"
chmod +x "$HELPER_DIR/wifi-actions.sh" "$HELPER_DIR/diagnose-call.sh" "$HELPER_DIR/wifi-update.sh"
info "Helpers → $HELPER_DIR/{wifi-actions,diagnose-call,wifi-update}.sh"

# Record where this repo lives so the Dashboard can self-update later.
printf 'REPO=%q\nINSTALLED_COMMIT=%s\n' "$SCRIPT_DIR" \
    "$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)" \
    > "$HELPER_DIR/install-info"
rm -f "$HELPER_DIR/.update-cache"   # fresh install == current

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
