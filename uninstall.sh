#!/bin/bash
set -e

BOLD="\033[1m"
GREEN="\033[32m"
RESET="\033[0m"

info() { echo -e "${BOLD}${GREEN}▸${RESET} $1"; }

PLUGIN_DIR="$HOME/Library/Application Support/SwiftBar/Plugins"
HELPER_DIR="$HOME/Library/Application Support/SwiftBar"

info "Removing wifi-health plugin…"
rm -f "$PLUGIN_DIR/wifi-health.10s.sh"
rm -f "$PLUGIN_DIR/wifi-activity.5s.sh"    # older split-plugin layout
rm -f "$PLUGIN_DIR/wifi-health.5m.sh"      # older filename
rm -f "$HELPER_DIR/wifi-info"
rm -f "$HELPER_DIR/gen-icon"
rm -rf "$HELPER_DIR/WifiHealth.app"
rm -f "$HELPER_DIR/wifi-actions.sh"
rm -f "$HELPER_DIR/diagnose-call.sh"
rm -f "$HELPER_DIR/wifi-update.sh"
rm -f "$HELPER_DIR/wifi-health.state"
rm -f "$HELPER_DIR/diagnose.result"
rm -f "$HELPER_DIR/install-info"
rm -f "$HELPER_DIR/.update-cache"
rm -rf "$HELPER_DIR/icons"

info "Done. SwiftBar itself was left in place."
echo "  To also remove SwiftBar: brew uninstall --cask swiftbar"
