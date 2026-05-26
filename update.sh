#!/bin/bash
set -e

BOLD="\033[1m"
GREEN="\033[32m"
RESET="\033[0m"

info() { echo -e "${BOLD}${GREEN}▸${RESET} $1"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

info "Pulling latest…"
git -C "$SCRIPT_DIR" pull --ff-only

info "Re-running install…"
bash "$SCRIPT_DIR/install.sh"
