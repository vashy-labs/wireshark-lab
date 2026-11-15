#!/usr/bin/env bash
# =============================================================
#  Scenario 11 - "The PC that gives itself an address"
#  Fault : the DHCP pool is full. Every address in it is leased to another
#          device. The new PC's DHCP requests reach the server, but the server
#          has nothing to offer, so the PC gives itself a 169.254.x.x address.
#  Output: captures/scenario-11.pcapng           new PC: no offer, falls back to 169.254.x.x
#          captures/scenario-11-server.pcapng    the same minute, captured at the DHCP server
#          captures/scenario-11-baseline.pcapng  new PC, pool with free addresses
#  Usage : cd ~/wireshark-lab && sudo ./scenarios/s11.sh
# =============================================================
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
require_root
trap cleanup EXIT
need dnsmasq dnsmasq-base
need dhcpcd dhcpcd-base

SW=s11-sw
PC=s11-pc
DHCP=s11-dhcp
PC_MAC=02:00:0a:6e:01:63

info "Building topology:  new PC and DHCP server 10.110.1.2 on one switch"
switch_add $SW
ns_add $PC
ns_add $DHCP
no_ipv6 $PC $DHCP
switch_port $SW $PC   eth0 $PC_MAC
switch_port $SW $DHCP eth0 02:00:0a:6e:01:02
addr $DHCP eth0 10.110.1.2/24

# The pool: four addresses, 10.110.1.100 - 10.110.1.103
POOL="--dhcp-range=10.110.1.100,10.110.1.103,255.255.255.0,8h"
OPTS="--dhcp-option=3,10.110.1.1 --dhcp-option=6,10.110.1.53 --dhcp-authoritative"

# leases <file> <count>  - write <count> current leases held by other devices
leases() {
  local f=$1 n=$2 i exp
  exp=$(( $(date +%s) + 6 * 3600 ))
  : > "$f"
  for ((i = 0; i < n; i++)); do
    printf '%s 02:00:0a:6e:09:%02x 10.110.1.%d laptop-%02d *\n' "$exp" $((i + 1)) $((100 + i)) $((i + 1)) >> "$f"
  done
}

# run <capture> <leases already taken> <seconds> [server-side capture]
run() {
  local out=$1 taken=$2 secs=$3 srv=${4:-}
  ip netns pids $DHCP | xargs -r kill 2>/dev/null || true    # stop the previous DHCP server
  sleep 0.5
  ip -n $PC addr flush dev eth0
  ip -n $PC route flush table main 2>/dev/null || true
  leases "$RUN_DIR/leases" "$taken"
  dhcp_server $DHCP eth0 s11-dhcpd $POOL $OPTS --dhcp-leasefile="$RUN_DIR/leases"
  [[ -n "$srv" ]] && capture2_start $DHCP eth0 "$srv"
  capture_start $PC eth0 "$out"
  dhcp_client $PC eth0 "$secs"
  sleep 2
  capture_stop ; capture_check "$out"
  [[ -n "$srv" ]] && { capture2_stop ; capture_check "$srv"; }
  printf "    %-22s %s\n" "DHCP Discover sent" "$(count "$out" "dhcp.option.dhcp == 1")"
  printf "    %-22s %s\n" "DHCP Offer received" "$(count "$out" "dhcp.option.dhcp == 2")"
  printf "    %-22s %s\n" "ARP probes 169.254" "$(count "$out" "arp.dst.proto_ipv4 == 169.254.0.0/16")"
  [[ -n "$srv" ]] && printf "    %-22s %s\n" "Discovers at server" "$(count "$srv" "dhcp.option.dhcp == 1")"
  echo "    DHCP server log:"
  grep -E "DHCPDISCOVER|DHCPOFFER|no address|DHCPACK" "$RUN_DIR/s11-dhcpd.log" 2>/dev/null \
    | sed 's/^.*dnsmasq-dhcp\[[0-9]*\]: [0-9]* //' | sort | uniq -c | sed 's/^/      /'
  return 0
}

info "Run 1/2: the pool has free addresses (baseline)"
run "$CAP_DIR/scenario-11-baseline.pcapng" 2 12

info "Run 2/2: all four addresses are leased to other devices (the problem)"
run "$CAP_DIR/scenario-11.pcapng" 4 40 "$CAP_DIR/scenario-11-server.pcapng"

info "Captures written:"
ls -lh "$CAP_DIR"/scenario-11*.pcapng
