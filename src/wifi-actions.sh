#!/bin/bash
# wifi-actions.sh — one-click remediations invoked by the SwiftBar plugin.
# Each action is intentionally small and non-destructive.

ACTION="$1"
shift

case "$ACTION" in
    portal)
        # Force a captive portal to show its login screen.
        #
        # Strategy: hit the URL macOS itself uses for captive portal
        # detection (captive.apple.com/hotspot-detect.html). Networks
        # that want to play nice with Macs *must* intercept this URL,
        # so it's far more reliable than something generic like
        # neverssl.com — many portals only hijack well-known detection
        # endpoints and ignore other HTTP traffic.
        #
        # Cache-buster query param prevents the browser from serving a
        # stale "page failed to load" from a previous attempt.
        #
        # If the primary URL doesn't trigger the portal, we also nudge
        # macOS's Captive Network Assistant in case the OS hasn't
        # already detected the portal itself.
        ts=$(date +%s)
        open "http://captive.apple.com/hotspot-detect.html?_=$ts"

        # Best-effort: launch Captive Network Assistant. Some macOS
        # versions only open it when the OS detects a portal itself,
        # so this is a soft attempt that fails silently if not supported.
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
