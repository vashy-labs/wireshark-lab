#!/usr/bin/env bash
# =============================================================
#  Scenario 10 - "Two machines, one address"
#  Fault : a new laptop is given an address that the file server already uses.
#          Both answer ARP for it. Whichever answer the PC believes decides
#          where its next connection goes.
#  Output: captures/scenario-10.pcapng           PC side: the laptop joins, requests start to fail
#          captures/scenario-10-baseline.pcapng  PC side: only the file server
#          captures/scenario-10-dad.pcapng       laptop side: an address check before use finds the conflict
#  Usage : cd ~/wireshark-lab && sudo ./scenarios/s10.sh
# =============================================================
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
require_root
trap cleanup EXIT
need arping iputils-arping

SW=s10-sw
PC=s10-pc
FS=s10-fs        # the file server, 10.100.1.20
NB=s10-laptop    # the new laptop
IP=10.100.1.20
SITE=files.lab.local

info "Building topology:  PC 10.100.1.10, file server 10.100.1.20 and a new laptop on one switch"
switch_add $SW
ns_add $PC
ns_add $FS
ns_add $NB
no_ipv6 $PC $FS $NB
switch_port $SW $PC eth0 02:00:0a:64:01:0a
switch_port $SW $FS eth0 02:00:0a:64:01:14
switch_port $SW $NB eth0 02:00:0a:64:01:77
addr $PC eth0 10.100.1.10/24
addr $FS eth0 $IP/24
# The file server answers after 1 ms, the laptop after anything between 0 and 2 ms, so it is
# not always the same machine that answers first. (Only the laptop gets the random delay:
# on the file server it would reorder the packets of the web page.)
tc -n $FS qdisc replace dev eth0 root netem delay 1ms
tc -n $NB qdisc replace dev eth0 root netem delay 1ms 1ms

info "Starting the file server's web interface"
web_server $FS $IP $SITE
head -c 2500 /dev/urandom > "$RUN_DIR/www/index.html"
chmod -R a+rX "$RUN_DIR/www"

# fetch <n>  - the PC opens the file server's page once (a new connection each time).
# Before each request the PC forgets its ARP entry, as a PC does after a minute or two
# without traffic, so it has to ask again who owns 10.100.1.20.
fetch() {
  local r rc=0
  ip -n $PC neigh flush dev eth0
  r=$(ip netns exec $PC curl -s -o /dev/null --connect-timeout 4 --resolve "$SITE:80:$IP" \
        -w '%{http_code}' "http://$SITE/") || rc=$?
  case "$rc" in
    0) printf "    request %-2s            works (HTTP %s)\n" "$1" "$r" ;;
    7) printf "    request %-2s            FAILS: connection refused\n" "$1" ;;
    *) printf "    request %-2s            FAILS: curl exit code %s\n" "$1" "$rc" ;;
  esac
  sleep 1
}

info "Run 1/3: only the file server uses 10.100.1.20 (baseline)"
capture_start $PC eth0 "$CAP_DIR/scenario-10-baseline.pcapng"
for i in 1 2 3; do fetch $i; done
capture_stop ; capture_check "$CAP_DIR/scenario-10-baseline.pcapng"

info "Run 2/3: the laptop is given 10.100.1.20 as well (the problem)"
capture_start $PC eth0 "$CAP_DIR/scenario-10.pcapng"
for i in 1 2 3; do fetch $i; done
echo "    -- the laptop is switched on with address $IP --"
ip netns exec $NB sysctl -qw net.ipv4.conf.eth0.arp_notify=1   # announce the address when it is added
addr $NB eth0 $IP/24
sleep 2
for i in 4 5 6 7 8 9 10 11 12; do fetch $i; done
capture_stop ; capture_check "$CAP_DIR/scenario-10.pcapng"
printf "    %-22s %s\n" "MACs answering ARP" \
  "$(tshark -r "$CAP_DIR/scenario-10.pcapng" -Y "arp.opcode == 2 && arp.src.proto_ipv4 == $IP" -T fields -e arp.src.hw_mac 2>/dev/null | sort | uniq -c | awk '{print $2 " (" $1 "x)"}' | paste -sd, -)"
printf "    %-22s %s\n" "TCP resets"  "$(count "$CAP_DIR/scenario-10.pcapng" "tcp.flags.reset == 1")"
printf "    %-22s %s\n" "duplicate-IP warnings" "$(count "$CAP_DIR/scenario-10.pcapng" "arp.duplicate-address-detected")"

info "Run 3/3: the laptop checks the address before using it"
ip -n $NB addr flush dev eth0
capture_start $NB eth0 "$CAP_DIR/scenario-10-dad.pcapng"
if ip netns exec $NB arping -D -q -c 2 -w 3 -I eth0 $IP; then
  echo "    address check          10.100.1.20 is free"
else
  echo "    address check          10.100.1.20 is ALREADY IN USE - the laptop does not take it"
fi
capture_stop ; capture_check "$CAP_DIR/scenario-10-dad.pcapng"

info "Captures written:"
ls -lh "$CAP_DIR"/scenario-10*.pcapng
