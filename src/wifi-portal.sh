#!/bin/bash
# wifi-portal.sh — diagnose and (best-effort) sign in to a captive portal
# from the terminal, without depending on a browser.
#
#   wifi-portal.sh probe   → find the portal; test HTTP/HTTPS reachability
#   wifi-portal.sh login   → probe, then best-effort submit a simple
#                            accept/continue form over plain HTTP
#
# Why this exists: browsers fight captive portals. Chrome's Secure DNS
# (DoH) + HTTPS-First bypass the portal's DNS interception; portals often
# redirect to an HTTPS auth page that refuses TLS; and macOS's own
# detection (captive.apple.com) fails when the network blocks DNS. curl
# lets us drive raw HTTP and, just as importantly, see *what* is reachable
# so we know whether it's fixable at all (vs. the auth server being down).

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

# Probe HTTP and HTTPS reachability of the portal host; sets globals.
HTTP_CODE=""; HTTPS_CODE=""
probe_host() {
    local host="$1"
    HTTP_CODE=$(curl -s -m 6 -A "$UA" -o /dev/null -w '%{http_code}' "http://$host/" 2>/dev/null)
    HTTPS_CODE=$(curl -s -m 6 -A "$UA" -o /dev/null -w '%{http_code}' "https://$host/" 2>/dev/null)
    [ "$HTTP_CODE" = "000" ] && HTTP_CODE="refused/timeout"
    [ "$HTTPS_CODE" = "000" ] && HTTPS_CODE="refused/timeout"
}

print_probe() {
    echo "${bold}${cyn}captive portal probe${rst}"
    local gw url host ip
    gw=$(gateway); echo "  gateway:  ${gw:-none}"
    if online; then echo "  ${grn}already online — no portal in the way.${rst}"; return 1; fi
    url=$(discover)
    if [ -z "$url" ]; then echo "  ${red}no portal redirect found — the network may be down.${rst}"; return 1; fi
    host=$(echo "$url" | sed -E 's#https?://([^/]+).*#\1#')
    ip=$(host -W 2 "$host" 2>/dev/null | awk '/has address/{print $4; exit}')
    echo "  portal:   $url"
    echo "  host:     $host  ${dim}(${ip:-does not resolve})${rst}"
    probe_host "$host"
    echo "  http://:  $HTTP_CODE"
    echo "  https://: $HTTPS_CODE"
    PORTAL_URL="$url"; PORTAL_HOST="$host"
    return 0
}

case "${1:-probe}" in
  probe)
    print_probe || exit 0
    echo
    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ] || [ "$HTTP_CODE" = "303" ]; then
        echo "${grn}The portal serves over plain HTTP — \`wifi-portal.sh login\` may sign you in.${rst}"
    elif echo "$HTTP_CODE$HTTPS_CODE" | grep -q refused; then
        echo "${red}The auth server is refusing connections — likely down. Not fixable from your end; reconnect or wait.${rst}"
    else
        echo "${ylw}Portal reachable but unusual response — try \`wifi-portal.sh login\`, or a browser.${rst}"
    fi
    ;;

  login)
    print_probe || exit 0
    echo
    echo "${bold}Attempting terminal sign-in…${rst}"
    # Prefer plain HTTP — the browser failure was an HTTPS-refused redirect.
    page=""
    for base in "http://$PORTAL_HOST/" "http://${PORTAL_URL#https://}" "$PORTAL_URL"; do
        page=$(curl -sS -m 8 -A "$UA" -c "$JAR" -b "$JAR" -L "$base" 2>/dev/null)
        [ -n "$page" ] && { echo "  fetched: $base"; break; }
    done
    if [ -z "$page" ]; then
        echo "  ${red}portal page won't load over HTTP or HTTPS — the auth server looks down.${rst}"
        echo "  ${dim}Nothing the client can do. Try Reconnect wifi, or wait it out.${rst}"
        exit 1
    fi
    # Common click-through pattern: one HTML <form> to accept terms.
    action=$(echo "$page" | grep -iEo '<form[^>]*action="[^"]*"' | head -1 | sed -E 's/.*action="([^"]*)".*/\1/')
    if [ -n "$action" ]; then
        case "$action" in
            http*) submit="$action" ;;
            //*)   submit="http:$action" ;;
            /*)    submit="http://$PORTAL_HOST$action" ;;
            *)     submit="http://$PORTAL_HOST/$action" ;;
        esac
        data=$(echo "$page" | grep -iEo '<input[^>]*>' | \
            awk 'match($0,/name="[^"]*"/){n=substr($0,RSTART+6,RLENGTH-7); v=""; if(match($0,/value="[^"]*"/)){v=substr($0,RSTART+7,RLENGTH-8)} printf "%s=%s&",n,v}')
        echo "  submitting form → $submit"
        curl -sS -m 10 -A "$UA" -c "$JAR" -b "$JAR" -L \
            --data "${data}accept=true&agree=true&submit=Connect" "$submit" >/dev/null 2>&1
    else
        echo "  ${ylw}no simple form found — this portal is probably JavaScript-driven.${rst}"
    fi
    sleep 2
    if online; then
        echo "  ${grn}✓ online — portal accepted.${rst}"
    else
        echo "  ${red}✗ still blocked.${rst} ${dim}Likely a JS/credentialed portal — open it in a browser, or the server is down.${rst}"
    fi
    ;;
esac
echo
echo "${dim}Done — close this window (Cmd-W) when finished.${rst}"
