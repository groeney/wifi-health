#!/bin/bash
# wifi-portal.sh — diagnose and (best-effort) sign in to a captive portal
# from the terminal, without depending on a browser.
#
#   wifi-portal.sh probe   → find the portal; test HTTP/HTTPS reachability
#   wifi-portal.sh login   → drive the portal over PLAIN HTTP and submit a
#                            simple accept/continue form
#   wifi-portal.sh dump    → print the raw portal page (HTTP) for sharing
#
# Why this exists: browsers fight captive portals. The hard real-world
# case (Caltrain): the portal lives on the gateway, plain HTTP returns a
# 302 that redirects to https://<portal>/authentication — but port 443 is
# REFUSED. Browsers (and a naive `curl -L`) follow into the dead HTTPS and
# give up. The fix is to stay strictly on HTTP (curl --proto-redir =http),
# which reaches the auth page the portal actually serves.

UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
JAR="$(mktemp -t wifiportal)"
trap 'rm -f "$JAR"' EXIT

bold=$'\033[1m'; dim=$'\033[2m'; grn=$'\033[32m'; ylw=$'\033[33m'; red=$'\033[31m'; cyn=$'\033[36m'; rst=$'\033[0m'

gateway() { route -n get default 2>/dev/null | awk '/gateway:/{print $2}'; }

online() {
    curl -s -m 4 "http://captive.apple.com/hotspot-detect.html" 2>/dev/null | grep -q "Success" && return 0
    ping -c1 -W2 1.1.1.1 >/dev/null 2>&1
}

# Discover the portal's login URL from the redirect the network returns
# for a DNS-free probe to the gateway, falling back to Apple's endpoint.
discover() {
    local gw url ts; gw=$(gateway); ts=$(date +%s)
    [ -n "$gw" ] && url=$(curl -s -m 5 -o /dev/null -w '%{redirect_url}' "http://$gw/?_=$ts" 2>/dev/null)
    [ -z "$url" ] && url=$(curl -s -m 5 -o /dev/null -w '%{redirect_url}' "http://captive.apple.com/hotspot-detect.html?_=$ts" 2>/dev/null)
    echo "$url"
}

PORTAL_URL=""; PORTAL_HOST=""; AUTH_PATH="/"; HTTP_CODE=""; HTTPS_CODE=""
probe_host() {
    local host="$1"
    HTTP_CODE=$(curl -s -m 6 -A "$UA" -o /dev/null -w '%{http_code}' "http://$host/" 2>/dev/null)
    HTTPS_CODE=$(curl -s -m 6 -A "$UA" -o /dev/null -w '%{http_code}' "https://$host/" 2>/dev/null)
    [ "$HTTP_CODE" = "000" ] && HTTP_CODE="refused/timeout"
    [ "$HTTPS_CODE" = "000" ] && HTTPS_CODE="refused/timeout"
}

print_probe() {
    echo "${bold}${cyn}captive portal probe${rst}"
    local gw url ip
    gw=$(gateway); echo "  gateway:  ${gw:-none}"
    if online; then echo "  ${grn}already online — no portal in the way.${rst}"; return 1; fi
    url=$(discover)
    if [ -z "$url" ]; then echo "  ${red}no portal redirect found — the network may be down.${rst}"; return 1; fi
    PORTAL_URL="$url"
    PORTAL_HOST=$(echo "$url" | sed -E 's#https?://([^/]+).*#\1#')
    AUTH_PATH=$(echo "$url" | sed -E 's#https?://[^/]+##'); [ -z "$AUTH_PATH" ] && AUTH_PATH="/"
    ip=$(host -W 2 "$PORTAL_HOST" 2>/dev/null | awk '/has address/{print $4; exit}')
    echo "  portal:   $url"
    echo "  host:     $PORTAL_HOST  ${dim}(${ip:-does not resolve})${rst}"
    probe_host "$PORTAL_HOST"
    echo "  http://:  $HTTP_CODE"
    echo "  https://: $HTTPS_CODE"
    return 0
}

# Fetch the portal/auth page over PLAIN HTTP, never following into HTTPS.
# Tries the auth path on both the hostname and the gateway IP. Echoes the
# body of the first candidate that returns content.
fetch_http() {
    local gw; gw=$(gateway)
    local u body
    for u in "http://$PORTAL_HOST$AUTH_PATH" "http://$gw$AUTH_PATH" "http://$PORTAL_HOST/" "http://$gw/"; do
        body=$(curl -sS -L --proto-redir =http -m 8 -A "$UA" -c "$JAR" -b "$JAR" "$u" 2>/dev/null)
        if [ -n "$body" ]; then FETCHED_URL="$u"; printf '%s' "$body"; return 0; fi
    done
    return 1
}

case "${1:-probe}" in
  probe)
    print_probe || exit 0
    echo
    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ] || [ "$HTTP_CODE" = "303" ]; then
        echo "${grn}HTTP is alive — \`wifi-portal.sh login\` can try to sign you in over plain HTTP.${rst}"
    elif echo "$HTTP_CODE$HTTPS_CODE" | grep -q refused; then
        echo "${red}Both HTTP and HTTPS refuse — the auth server is down. Reconnect or wait.${rst}"
    fi
    ;;

  dump)
    print_probe || exit 0
    echo
    echo "${bold}Raw portal page over HTTP${rst} ${dim}(share this so the login flow can be tuned)${rst}"
    body=$(fetch_http) || { echo "${red}couldn't load over plain HTTP.${rst}"; exit 1; }
    echo "  from: $FETCHED_URL"
    echo "  ---"
    printf '%s\n' "$body" | head -60
    ;;

  login)
    print_probe || exit 0
    echo
    echo "${bold}Attempting terminal sign-in (plain HTTP)…${rst}"
    page=$(fetch_http)
    if [ -z "$page" ]; then
        echo "  ${red}✗ the portal only answers over HTTPS, and HTTPS is refused.${rst}"
        echo "  ${dim}This portal is broken/down at the network end — not fixable from any device."
        echo "  Try Reconnect wifi, move to another car, or use a hotspot.${rst}"
        exit 1
    fi
    echo "  loaded: $FETCHED_URL"
    # Common click-through pattern: an HTML <form> to accept terms.
    action=$(echo "$page" | grep -iEo '<form[^>]*action="[^"]*"' | head -1 | sed -E 's/.*action="([^"]*)".*/\1/')
    if [ -n "$action" ]; then
        case "$action" in
            http://*)  submit="$action" ;;
            https://*) submit="http://${action#https://}" ;;   # force HTTP
            //*)       submit="http:$action" ;;
            /*)        submit="http://$PORTAL_HOST$action" ;;
            *)         submit="http://$PORTAL_HOST/$action" ;;
        esac
        data=$(echo "$page" | grep -iEo '<input[^>]*>' | \
            awk 'match($0,/name="[^"]*"/){n=substr($0,RSTART+6,RLENGTH-7); v=""; if(match($0,/value="[^"]*"/)){v=substr($0,RSTART+7,RLENGTH-8)} printf "%s=%s&",n,v}')
        echo "  submitting form → $submit"
        curl -sS -L --proto-redir =http -m 10 -A "$UA" -c "$JAR" -b "$JAR" \
            --data "${data}accept=true&agree=true&terms=on&submit=Connect" "$submit" >/dev/null 2>&1
    else
        echo "  ${ylw}no HTML form found — the page is probably JavaScript-driven.${rst}"
        echo "  ${dim}Run \`wifi-portal.sh dump\` and share the output to tune the flow.${rst}"
    fi
    sleep 2
    if online; then
        echo "  ${grn}✓ online — portal accepted.${rst}"
    else
        echo "  ${red}✗ still blocked.${rst} ${dim}Try \`wifi-portal.sh dump\` to inspect the page.${rst}"
    fi
    ;;
esac
echo
echo "${dim}Done — close this window (Cmd-W) when finished.${rst}"
