#!/usr/bin/env bash
# =============================================================
#  Scenario 28 - "Who is the gateway now?"
#  What you see: a machine on the LAN keeps announcing, every three seconds, that the
#          gateway's address 10.71.1.1 belongs to it. PCs that believe it send their
#          internet traffic to that machine instead of the router, and lose the internet.
#          A rogue claim on the gateway's address is the signature of ARP spoofing.
#  Output: captures/scenario-28.pcapng           the office PC, the announcements start
#          captures/scenario-28-baseline.pcapng  the office PC, a normal minute
#  Usage : cd ~/wireshark-lab && sudo ./scenarios/s28.sh
# =============================================================
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
require_root
trap cleanup EXIT
need arping iputils-arping

SW=s28-sw
PC=s28-pc         # office PC, 10.71.1.20
RTR=s28-rtr       # the real gateway, 10.71.1.1
SRV=s28-srv       # a server behind the gateway, 10.71.2.80
ROGUE=s28-rogue   # the machine that claims the gateway's address, 10.71.1.66

info "Building topology:  office PC, gateway and one more machine on a switch; a server behind the gateway"
switch_add $SW
ns_add $PC
ns_add $RTR
ns_add $SRV
ns_add $ROGUE
no_ipv6 $PC $RTR $SRV $ROGUE
switch_port $SW $PC    eth0 02:00:0a:47:01:14
switch_port $SW $RTR   eth0 02:00:0a:47:01:01
switch_port $SW $ROGUE eth0 02:00:0a:47:01:42
veth $RTR eth1 02:00:0a:47:02:01   $SRV eth0 02:00:0a:47:02:50
addr $PC    eth0 10.71.1.20/24 ;  gw $PC 10.71.1.1
addr $RTR   eth0 10.71.1.1/24  ;  addr $RTR eth1 10.71.2.1/24 ;  router $RTR
addr $SRV   eth0 10.71.2.80/24 ;  gw $SRV 10.71.2.1
addr $ROGUE eth0 10.71.1.66/24

web_server $SRV 10.71.2.80 portal.lab.local
head -c 1500 /dev/urandom | base64 > "$RUN_DIR/www/index.html"
chmod -R a+rX "$RUN_DIR/www"

# browse <seconds>  - the PC opens the portal once a second
browse() {
  local ok=0 fail=0
  for _ in $(seq 1 "$1"); do
    if ip netns exec $PC curl --noproxy "*" -s -o /dev/null --max-time 1 --resolve portal.lab.local:80:10.71.2.80 http://portal.lab.local/; then
      ok=$((ok + 1)); else fail=$((fail + 1)); fi
    sleep 1
  done
  printf "    %-24s %s works, %s fail\n" "portal (once a second)" "$ok" "$fail"
}

info "Run 1/2: a normal minute (baseline)"
capture_start $PC eth0 "$CAP_DIR/scenario-28-baseline.pcapng"
browse 6
capture_stop ; capture_check "$CAP_DIR/scenario-28-baseline.pcapng"

info "Run 2/2: the machine at 10.71.1.66 starts announcing 10.71.1.1 as its own (the problem)"
capture_start $PC eth0 "$CAP_DIR/scenario-28.pcapng"
ip -n $PC neigh flush dev eth0      # the PC asks for the gateway afresh, so the real answer is in the capture
browse 4 &
B=$!
sleep 3
# It takes the gateway's address as a second address (without checking first), and
# announces it with unsolicited ARP every three seconds or so.
ip -n $ROGUE addr add 10.71.1.1/32 dev eth0 nodad 2>/dev/null || ip -n $ROGUE addr add 10.71.1.1/32 dev eth0
ip netns exec $ROGUE sh -c 'for i in 1 2 3 4 5 6 7 8; do arping -U -q -c 1 -I eth0 -s 10.71.1.1 10.71.1.1; sleep 2; done' &
R=$!
wait $B
browse 12
wait $R 2>/dev/null || true
capture_stop ; capture_check "$CAP_DIR/scenario-28.pcapng"

printf "    %-24s %s\n" "MACs claiming 10.71.1.1" \
  "$(tshark -r "$CAP_DIR/scenario-28.pcapng" -Y "arp.src.proto_ipv4 == 10.71.1.1" -T fields -e arp.src.hw_mac 2>/dev/null | sort | uniq -c | awk '{print $2 " (" $1 "x)"}' | paste -sd, -)"
printf "    %-24s %s\n" "duplicate-IP warnings" "$(count "$CAP_DIR/scenario-28.pcapng" "arp.duplicate-address-detected")"

info "Captures written:"
ls -lh "$CAP_DIR"/scenario-28*.pcapng
