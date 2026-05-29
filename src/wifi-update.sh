#!/bin/bash
# wifi-update.sh — check for / apply updates to wifi-health.
#
#   wifi-update.sh check  → prints: available | current | unknown
#   wifi-update.sh apply  → git pull (ff-only) + re-run install.sh
#
# The repo path is recorded by install.sh in install-info, so the app
# can self-update without the user remembering where they cloned it.

HELPER_DIR="$HOME/Library/Application Support/SwiftBar"
INFO="$HELPER_DIR/install-info"
CACHE="$HELPER_DIR/.update-cache"

REPO=""
[ -f "$INFO" ] && . "$INFO"

case "${1:-check}" in
    check)
        # Reuse a recent result (<=6h) so we don't git-fetch constantly.
        if [ -f "$CACHE" ]; then
            . "$CACHE"
            if [ -n "${CHECKED_AT:-}" ] && [ $(( $(date +%s) - CHECKED_AT )) -lt 21600 ]; then
                echo "${UPDATE_STATE:-unknown}"; exit 0
            fi
        fi
        state="unknown"
        if [ -n "$REPO" ] && [ -d "$REPO/.git" ]; then
            if git -C "$REPO" fetch -q origin 2>/dev/null; then
                branch=$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null)
                local_sha=$(git -C "$REPO" rev-parse HEAD 2>/dev/null)
                remote_sha=$(git -C "$REPO" rev-parse "origin/${branch:-main}" 2>/dev/null)
                if [ -n "$local_sha" ] && [ -n "$remote_sha" ]; then
                    [ "$local_sha" = "$remote_sha" ] && state="current" || state="available"
                fi
            fi
        fi
        printf 'CHECKED_AT=%s\nUPDATE_STATE=%s\n' "$(date +%s)" "$state" > "$CACHE"
        echo "$state"
        ;;
    apply)
        [ -z "$REPO" ] && { echo "no repo recorded"; exit 1; }
        [ -d "$REPO/.git" ] || { echo "repo missing at $REPO"; exit 1; }
        git -C "$REPO" pull --ff-only && bash "$REPO/install.sh"
        rm -f "$CACHE"
        ;;
esac
