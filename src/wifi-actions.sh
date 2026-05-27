#!/bin/bash
# wifi-actions.sh — one-click remediations invoked by the SwiftBar plugin.
# Each action is intentionally small and non-destructive.

ACTION="$1"
shift

case "$ACTION" in
    portal)
        # Force a captive portal to show its login screen by loading a
        # plain-HTTP URL the portal can intercept. neverssl.com is
        # purpose-built for this — guaranteed never to use HTTPS.
        open "http://neverssl.com/"
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
