#!/bin/bash
# fix-dns.sh — DNS helper for the wifi-health widget.
#
# Fixes the "Safari loads it but Chrome says DNS_PROBE_FINISHED_NXDOMAIN" case:
# a stale *negative* DNS cache (often on a phone-hotspot resolver) holding the
# old NXDOMAIN for a just-created / recently-changed hostname. The resolver
# remembers "no such name" up to the zone's SOA negative-TTL (often 30 min).
# Chrome uses that resolver; Safari often dodges it via iCloud Private Relay.
# Flushing + switching to Cloudflare 1.1.1.1 bypasses the stale resolver right
# away — even while still on the hotspot.
#
#   fix-dns.sh                  diagnose (resolution across resolvers + negative-TTL)
#   fix-dns.sh --gui            flush DNS + use Cloudflare 1.1.1.1  (admin prompt + notification)
#   fix-dns.sh --revert         revert Wi-Fi DNS to automatic / DHCP (admin prompt + notification)
#   HOST=example.com fix-dns.sh diagnose a specific hostname
set -uo pipefail
HOST="${HOST:-}"
svc=$(networksetup -listallnetworkservices 2>/dev/null | grep -iE 'wi-?fi' | head -1)
[ -z "$svc" ] && svc="Wi-Fi"

case "${1:-}" in
  --gui)
    osascript <<OSA
do shell script "dscacheutil -flushcache; killall -HUP mDNSResponder; networksetup -setdnsservers ${svc} 1.1.1.1 1.0.0.1" with administrator privileges with prompt "Fix DNS — flush cache & use Cloudflare 1.1.1.1"
display notification "Cache flushed · ${svc} now resolving via 1.1.1.1" with title "Fix DNS ✅"
OSA
    ;;
  --revert)
    osascript <<OSA
do shell script "networksetup -setdnsservers ${svc} Empty; dscacheutil -flushcache; killall -HUP mDNSResponder" with administrator privileges with prompt "Revert DNS to automatic (DHCP)"
display notification "${svc} DNS back to automatic" with title "DNS reverted"
OSA
    ;;
  ""|--diagnose)
    echo "DNS diagnosis${HOST:+ — $HOST}"
    echo "  Wi-Fi service : $svc"
    echo "  current DNS   : $(networksetup -getdnsservers "$svc" 2>/dev/null | paste -sd' ' -)"
    if [ -n "$HOST" ]; then
      echo "  system resolver    : $(dig +short "$HOST" | tr '\n' ' ')"
      echo "  Cloudflare 1.1.1.1 : $(dig +short "$HOST" @1.1.1.1 | tr '\n' ' ')"
      echo "  Google 8.8.8.8     : $(dig +short "$HOST" @8.8.8.8 | tr '\n' ' ')"
      zone=$(echo "$HOST" | awk -F. '{print $(NF-1)"."$NF}')
      echo "  negative-TTL (SOA min, $zone): $(dig +short "$zone" SOA | awk '{print $NF}')s"
    fi
    echo
    echo "Fix:  $0 --gui     (flush + Cloudflare 1.1.1.1)"
    echo "Undo: $0 --revert  (back to automatic DNS)"
    ;;
  *) echo "usage: $0 [--gui|--revert|--diagnose]   (HOST=name for host diagnosis)" >&2; exit 1 ;;
esac
