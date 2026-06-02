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
        # Get a captive portal's login screen to actually load.
        #
        # The hard case (e.g. Caltrain): the network blocks DNS for
        # everything except its own portal domain, and the user's default
        # browser is Chrome — whose Secure DNS (DoH) and HTTPS-First mode
        # bypass the portal's DNS interception and force https://, which
        # portals can't serve. Result: DNS_PROBE / CONNECTION_REFUSED.
        #
        # Strategy:
        #   1. Discover the portal's real login URL by reading the redirect
        #      the network returns for a plain-HTTP probe to the gateway IP
        #      (DNS-free), falling back to Apple's detection URL.
        #   2. Open it in SAFARI, not the default browser — Safari uses the
        #      system resolver and plain HTTP, so the portal can intercept
        #      and redirect it. This is the key fix for the Chrome failure.
        #   3. Nudge macOS's Captive Network Assistant as a backstop.
        ts=$(date +%s)
        gateway=$(route -n get default 2>/dev/null | awk '/gateway:/ {print $2}')

        # 1. Discover the portal URL from the redirect Location (DNS-free).
        portal_url=""
        if [ -n "$gateway" ]; then
            portal_url=$(curl -s -m 4 -o /dev/null -w '%{redirect_url}' "http://$gateway/?_=$ts" 2>/dev/null)
        fi
        if [ -z "$portal_url" ]; then
            portal_url=$(curl -s -m 4 -o /dev/null -w '%{redirect_url}' "http://captive.apple.com/hotspot-detect.html?_=$ts" 2>/dev/null)
        fi

        # 2. Open in Safari (system DNS + plain HTTP, portal-friendly).
        if [ -n "$portal_url" ]; then
            open -a Safari "$portal_url"
        elif [ -n "$gateway" ]; then
            open -a Safari "http://$gateway/?_=$ts"
        else
            open -a Safari "http://captive.apple.com/hotspot-detect.html?_=$ts"
        fi

        # 3. Captive Network Assistant (silent if unsupported).
        CNA="/System/Library/CoreServices/Captive Network Assistant.app"
        [ -d "$CNA" ] && open -a "$CNA" 2>/dev/null &
        ;;

    portal-terminal)
        # Browser-independent path: diagnose the portal and attempt a
        # terminal sign-in over plain HTTP. Runs in Terminal so the
        # diagnostic readout is visible (it explains *why* if it can't
        # — e.g. auth server down, or a JavaScript-only portal).
        DIAG="$HELPER_DIR/wifi-portal.sh"
        osascript <<APPLESCRIPT
tell application "Terminal"
    activate
    do script "bash '$DIAG' login"
end tell
APPLESCRIPT
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

    fix-dns)
        # Flush the DNS cache + resolve via Cloudflare 1.1.1.1 — fixes a stale
        # negative cache (e.g. a hotspot resolver holding NXDOMAIN for a freshly
        # created hostname). Logic lives in the fix-dns.sh helper.
        "$HELPER_DIR/fix-dns.sh" --gui
        ;;

    dns-auto)
        # Revert Wi-Fi DNS to automatic / DHCP (undo fix-dns). Try without
        # an admin prompt first — that works for admin users (the common
        # case) and keeps the fix one frictionless click; fall back to the
        # helper's privileged path only if it's refused.
        if networksetup -setdnsservers Wi-Fi Empty 2>/dev/null; then
            dscacheutil -flushcache 2>/dev/null
            osascript -e 'display notification "Wi-Fi DNS back to automatic (DHCP)" with title "DNS reverted"' 2>/dev/null
        else
            "$HELPER_DIR/fix-dns.sh" --revert
        fi
        ;;

    *)
        echo "Unknown action: $ACTION" >&2
        exit 1
        ;;
esac
