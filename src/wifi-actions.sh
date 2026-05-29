#!/bin/bash
# wifi-actions.sh — one-click remediations invoked by the SwiftBar plugin.
# Each action is intentionally small and non-destructive.

HELPER_DIR="$HOME/Library/Application Support/SwiftBar"

ACTION="$1"
shift

case "$ACTION" in
    dashboard)
        # Launch the advanced pop-out via `open` so it runs fully
        # detached from SwiftBar (own process/session) — buttons inside
        # it work and it survives after the click returns.
        open "$HELPER_DIR/WifiHealth.app"
        ;;

    diagnose)
        # Run the call-quality probe in the background and surface the
        # result inside the menu bar dropdown (no Terminal window).
        # Mark "running" synchronously so the immediate refresh shows
        # progress, then launch the probe detached — it writes the
        # structured result file when done (~15s later).
        RESULT="$HELPER_DIR/diagnose.result"
        printf 'DIAG_STATUS=running\nDIAG_START=%s\n' "$(date +%s)" > "$RESULT"
        nohup "$HELPER_DIR/diagnose-call.sh" --widget >/dev/null 2>&1 &
        ;;

    portal)
        # Force a captive portal to show its login screen.
        #
        # Three-pronged strategy to handle different portal behaviors:
        #
        # 1. Open the default gateway IP directly. This is the most
        #    reliable approach because it bypasses DNS entirely — and
        #    DNS is *frequently* blocked by transit/airport portals
        #    (confirmed on Caltrain wifi). The gateway is the device
        #    running the portal, so http://<gateway>/ reaches it
        #    even when nothing resolves.
        #
        # 2. Also open Apple's captive detection URL with a cache-buster.
        #    Works when DNS is functional but the network only intercepts
        #    well-known detection endpoints. macOS uses this URL itself,
        #    so portals that want to be Mac-friendly will intercept it.
        #
        # 3. Best-effort nudge the Captive Network Assistant for cases
        #    where macOS hasn't yet detected the portal on its own.
        ts=$(date +%s)

        # Method 1: gateway IP (DNS-free, the Caltrain case)
        gateway=$(route -n get default 2>/dev/null | awk '/gateway:/ {print $2}')
        if [ -n "$gateway" ]; then
            open "http://$gateway/?_=$ts"
        fi

        # Method 2: Apple's captive detection URL (DNS-required fallback)
        open "http://captive.apple.com/hotspot-detect.html?_=$ts"

        # Method 3: Captive Network Assistant (silent if unsupported)
        CNA="/System/Library/CoreServices/Captive Network Assistant.app"
        [ -d "$CNA" ] && open -a "$CNA" 2>/dev/null &
        ;;

    reconnect)
        # Toggle wifi off/on. Fixes stuck DHCP leases, stale routes,
        # and "great signal but no traffic" conditions. Works without
        # sudo on macOS 12+.
        networksetup -setairportpower en0 off
        sleep 2
        networksetup -setairportpower en0 on
        ;;

    switch)
        # Join a saved network. Password comes from the keychain, so
        # this only works for networks you've connected to before.
        local_ssid="$1"
        if [ -z "$local_ssid" ]; then
            osascript -e 'display notification "No network specified" with title "wifi-health"'
            exit 1
        fi
        networksetup -setairportnetwork en0 "$local_ssid"
        ;;

    settings)
        # Open the Wi-Fi pane in System Settings.
        open "x-apple.systempreferences:com.apple.wifi-settings-extension"
        ;;

    recheck)
        # Bust the heavy-check cache so the next refresh runs ping,
        # captive portal, DNS, and HTTPS checks immediately instead of
        # using the stale cached state. Useful when "the dot says green
        # but nothing loads" — usually means cached results predate the
        # connectivity problem.
        rm -f "$HOME/Library/Application Support/SwiftBar/wifi-health.state"
        ;;

    speed-test)
        # Run Apple's built-in network quality test in a Terminal window
        # so the user can watch progress. Takes 10-20 seconds.
        osascript <<APPLESCRIPT
tell application "Terminal"
    activate
    do script "echo 'Running network quality test (10-20 seconds)…'; networkQuality; echo; read -n 1 -s -r -p 'Press any key to close…'; exit"
end tell
APPLESCRIPT
        ;;

    *)
        echo "Unknown action: $ACTION" >&2
        exit 1
        ;;
esac
