#!/usr/bin/env bash
# =============================================================
#  Scenario 12 - "The wrong network after lunch"
#  Fault : a rogue DHCP server. Someone has plugged a small home router into a
#          meeting-room socket. It answers DHCP requests faster than the real
#          server and hands out its own addresses and its own gateway.
#  Output: captures/scenario-12.pcapng           PC side: two offers, the PC takes the wrong one
#          captures/scenario-12-baseline.pcapng  PC side: only the company DHCP server
#  Usage : cd ~/wireshark-lab && sudo ./scenarios/s12.sh
# =============================================================
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
require_root
trap cleanup EXIT
need dnsmasq dnsmasq-base
need dhcpcd dhcpcd-base

SW=s12-sw
PC=s12-pc
DHCP=s12-dhcp     # the company DHCP server, 10.120.1.2
ROGUE=s12-rogue   # the home router, 192.168.1.1
RTR=s12-rtr
SRV=s12-srv
SERVER_IP=10.120.2.20
SITE=intranet.lab.local

info "Building topology:  PC, company DHCP server, router and (later) a home router on one switch"
switch_add $SW
ns_add $PC
ns_add $DHCP
ns_add $ROGUE
ns_add $RTR
ns_add $SRV
no_ipv6 $PC $DHCP $ROGUE $RTR $SRV
switch_port $SW $PC    eth0 02:00:0a:78:01:0a
switch_port $SW $DHCP  eth0 02:00:0a:78:01:02
switch_port $SW $RTR   eth0 02:00:0a:78:01:01
veth $RTR eth1 02:00:0a:78:02:01   $SRV eth0 02:00:0a:78:02:14
addr $DHCP eth0 10.120.1.2/24 ;  gw $DHCP 10.120.1.1
addr $RTR  eth0 10.120.1.1/24 ;  addr $RTR eth1 10.120.2.1/24 ;  router $RTR
addr $SRV  eth0 $SERVER_IP/24 ;  gw $SRV 10.120.2.1

info "Starting the intranet server"
web_server $SRV $SERVER_IP $SITE
head -c 3000 /dev/urandom > "$RUN_DIR/www/index.html"
chmod -R a+rX "$RUN_DIR/www"

# company_dhcp  - (re)start the company DHCP server with no leases, so the PC is a new
# client each time. Like most real DHCP servers it checks that an address is free
# (here with a ping) before it offers it, which takes it a few seconds.
company_dhcp() {
  ip netns pids $DHCP | xargs -r kill 2>/dev/null || true
  sleep 0.5
  rm -f "$RUN_DIR/company.leases"
  dhcp_server $DHCP eth0 company --dhcp-range=10.120.1.100,10.120.1.199,255.255.255.0,8h \
    --dhcp-option=3,10.120.1.1 --dhcp-option=6,10.120.1.53 --dhcp-authoritative \
    --dhcp-leasefile="$RUN_DIR/company.leases"
}

# run <capture>  - the PC starts up, gets an address, and opens the intranet
run() {
  local out=$1 r rc=0
  company_dhcp
  ip -n $RTR neigh flush all ; ip -n $DHCP neigh flush all   # forget the previous run's PC
  ip -n $PC addr flush dev eth0
  ip -n $PC route flush table main 2>/dev/null || true
  capture_start $PC eth0 "$out"
  dhcp_client $PC eth0 12
  r=$(ip netns exec $PC curl -s -o /dev/null --connect-timeout 6 --resolve "$SITE:80:$SERVER_IP" \
        -w '%{http_code} %{time_total}' "http://$SITE/") || rc=$?
  sleep 1
  capture_stop ; capture_check "$out"
  awk -v r="$r" -v rc="$rc" 'BEGIN { split(r, a, " ");
    printf "    intranet (browser)     HTTP %s, curl exit code %s, after %.1f s\n", a[1], rc, a[2] }'
  printf "    %-22s %s\n" "DHCP offers from" \
    "$(tshark -r "$out" -Y "dhcp.option.dhcp == 2" -T fields -e dhcp.option.dhcp_server_id 2>/dev/null | paste -sd, -)"
  printf "    %-22s %s\n" "PC requested from" \
    "$(tshark -r "$out" -Y "dhcp.option.dhcp == 3" -T fields -e dhcp.option.dhcp_server_id 2>/dev/null | paste -sd, -)"
}

info "Run 1/2: only the company DHCP server (baseline)"
run "$CAP_DIR/scenario-12-baseline.pcapng"

info "Run 2/2: a home router is plugged into the meeting room (the problem)"
switch_port $SW $ROGUE eth0 a2:4c:9e:31:7f:10
addr $ROGUE eth0 192.168.1.1/24
dhcp_server $ROGUE eth0 rogue --dhcp-range=192.168.1.100,192.168.1.199,255.255.255.0,24h \
  --dhcp-option=3,192.168.1.1 --dhcp-option=6,192.168.1.1 --no-ping \
  --dhcp-leasefile="$RUN_DIR/rogue.leases"
run "$CAP_DIR/scenario-12.pcapng"

info "Captures written:"
ls -lh "$CAP_DIR"/scenario-12*.pcapng
