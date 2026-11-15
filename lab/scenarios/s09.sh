#!/usr/bin/env bash
# =============================================================
#  Scenario 09 - "One PC cannot leave the building"
#  Fault : a typing error in one PC's network settings. The PC can still reach
#          the printer next to it, but nothing beyond the router.
#  Output: captures/scenario-09.pcapng           wrong default gateway (10.90.1.254 instead of .1)
#          captures/scenario-09-mask.pcapng      wrong subnet mask (/16 instead of /24)
#          captures/scenario-09-baseline.pcapng  correct settings
#  Usage : cd ~/wireshark-lab && sudo ./scenarios/s09.sh
# =============================================================
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
require_root
trap cleanup EXIT

SW=s09-sw
PC=s09-pc
PRN=s09-printer
RTR=s09-rtr
SRV=s09-srv
SERVER_IP=10.90.2.20
PRINTER_IP=10.90.1.30
SITE=intranet.lab.local

info "Building topology:  PC 10.90.1.10 and printer 10.90.1.30 on a switch --- router --- server 10.90.2.20"
switch_add $SW
ns_add $PC
ns_add $PRN
ns_add $RTR
ns_add $SRV
no_ipv6 $PC $PRN $RTR $SRV
switch_port $SW $PC  eth0 02:00:0a:5a:01:0a
switch_port $SW $PRN eth0 02:00:0a:5a:01:1e
switch_port $SW $RTR eth0 02:00:0a:5a:01:01
veth $RTR eth1 02:00:0a:5a:02:01   $SRV eth0 02:00:0a:5a:02:14
addr $PRN eth0 $PRINTER_IP/24 ;  gw $PRN 10.90.1.1
addr $RTR eth0 10.90.1.1/24   ;  addr $RTR eth1 10.90.2.1/24 ;  router $RTR
addr $SRV eth0 10.90.2.20/24  ;  gw $SRV 10.90.2.1
tc -n $RTR qdisc replace dev eth1 root netem delay 2ms

info "Starting the intranet server"
web_server $SRV $SERVER_IP $SITE
head -c 3000 /dev/urandom > "$RUN_DIR/www/index.html"
chmod -R a+rX "$RUN_DIR/www"

# run <capture> <PC address/prefix> <PC gateway>
#   The user prints a page (pings the printer), then opens the intranet.
run() {
  local out=$1 r rc=0
  ip -n $PC addr flush dev eth0
  addr $PC eth0 "$2"
  gw $PC "$3"
  ip -n $PC neigh flush all
  capture_start $PC eth0 "$out"
  ip netns exec $PC ping -c 2 -i 0.5 -W 2 $PRINTER_IP >/dev/null 2>&1 \
    && echo "    printer (ping)         works" || echo "    printer (ping)         FAILS"
  r=$(ip netns exec $PC curl -s -o /dev/null --connect-timeout 8 --resolve "$SITE:80:$SERVER_IP" \
        -w '%{http_code} %{time_total}' "http://$SITE/") || rc=$?
  sleep 1
  capture_stop ; capture_check "$out"
  awk -v r="$r" -v rc="$rc" 'BEGIN { split(r, a, " ");
    printf "    intranet (browser)     HTTP %s, curl exit code %s, after %.1f s\n", a[1], rc, a[2] }'
  printf "    %-22s %s\n" "ARP requests from PC" "$(count "$out" "arp.opcode == 1 && arp.src.proto_ipv4 == 10.90.1.10")"
  printf "    %-22s %s\n" "ARP asked for" \
    "$(tshark -r "$out" -Y "arp.opcode == 1 && arp.src.proto_ipv4 == 10.90.1.10" -T fields -e arp.dst.proto_ipv4 2>/dev/null | sort | uniq -c | awk '{print $2 " (" $1 "x)"}' | paste -sd, -)"
  printf "    %-22s %s\n" "ARP replies to PC" "$(count "$out" "arp.opcode == 2 && arp.dst.proto_ipv4 == 10.90.1.10")"
}

info "Run 1/3: correct settings (baseline)"
run "$CAP_DIR/scenario-09-baseline.pcapng" 10.90.1.10/24 10.90.1.1

info "Run 2/3: default gateway typed as 10.90.1.254 (the problem)"
run "$CAP_DIR/scenario-09.pcapng" 10.90.1.10/24 10.90.1.254

info "Run 3/3: subnet mask typed as 255.255.0.0 (/16)"
run "$CAP_DIR/scenario-09-mask.pcapng" 10.90.1.10/16 10.90.1.1

info "Captures written:"
ls -lh "$CAP_DIR"/scenario-09*.pcapng
