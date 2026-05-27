#!/bin/bash
set -e

BOLD="\033[1m"
GREEN="\033[32m"
RESET="\033[0m"

info() { echo -e "${BOLD}${GREEN}▸${RESET} $1"; }

PLUGIN_DIR="$HOME/Library/Application Support/SwiftBar/Plugins"
HELPER_DIR="$HOME/Library/Application Support/SwiftBar"

info "Removing wifi-health plugins…"
rm -f "$PLUGIN_DIR/wifi-health.10s.sh"
rm -f "$PLUGIN_DIR/wifi-activity.5s.sh"
rm -f "$PLUGIN_DIR/wifi-health.5m.sh"      # older filename
rm -f "$HELPER_DIR/wifi-info"
rm -f "$HELPER_DIR/wifi-actions.sh"
rm -f "$HELPER_DIR/wifi-health.state"

info "Done. SwiftBar itself was left in place."
echo "  To also remove SwiftBar: brew uninstall --cask swiftbar"
