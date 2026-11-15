#!/usr/bin/env bash
# =============================================================
#  Scenario 14 - "The packet that never arrives"
#  Fault : a routing loop. The core router still sends the old branch network
#          10.140.50.0/24 to the branch router. The branch router no longer has
#          that network and sends everything it does not know back to the core.
#  Output: captures/scenario-14.pcapng        PC side: ping, traceroute and a connection attempt
#          captures/scenario-14-core.pcapng   the link between the two routers at the same moment
#  Usage : cd ~/wireshark-lab && sudo ./scenarios/s14.sh
# =============================================================
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
require_root
trap cleanup EXIT

PC=s14-pc
CORE=s14-core     # head-office core router
BR=s14-branch     # branch router
TARGET=10.140.50.10

info "Building topology:  PC 10.140.1.10 --- core router === branch router"
ns_add $PC
ns_add $CORE
ns_add $BR
no_ipv6 $PC $CORE $BR
veth $PC   eth0 02:00:0a:8c:01:0a   $CORE eth0 02:00:0a:8c:01:01
veth $CORE eth1 02:00:0a:8c:09:01   $BR   eth0 02:00:0a:8c:09:02
addr $PC   eth0 10.140.1.10/24 ;  gw $PC 10.140.1.1
addr $CORE eth0 10.140.1.1/24  ;  addr $CORE eth1 10.140.9.1/30 ;  router $CORE
addr $BR   eth0 10.140.9.2/30  ;  router $BR
tc -n $CORE qdisc replace dev eth1 root netem delay 1ms
tc -n $BR   qdisc replace dev eth0 root netem delay 1ms

info "Routes: core -> 10.140.50.0/24 via branch (left over);  branch -> everything else via core"
ip -n $CORE route add 10.140.50.0/24 via 10.140.9.2
ip -n $BR   route add default via 10.140.9.1

capture2_start $CORE eth1 "$CAP_DIR/scenario-14-core.pcapng"
capture_start  $PC   eth0 "$CAP_DIR/scenario-14.pcapng"
{ ip netns exec $PC ping -c 2 -i 1 -W 2 $TARGET 2>&1 || true; } | grep -E "exceeded|transmitted" | sed 's/^/    ping: /'
echo "    traceroute:"
{ ip netns exec $PC traceroute -n -N 1 -q 1 -w 1 -m 12 $TARGET 2>&1 || true; } | sed 's/^/      /'
ip netns exec $PC curl -s -o /dev/null --connect-timeout 4 http://$TARGET/ \
  && echo "    web page               loads" || echo "    web page               FAILS (curl exit code $?)"
sleep 1
capture_stop ; capture2_stop
capture_check "$CAP_DIR/scenario-14.pcapng" ; capture_check "$CAP_DIR/scenario-14-core.pcapng"
printf "    %-22s %s\n" "ICMP time exceeded" "$(count "$CAP_DIR/scenario-14.pcapng" "icmp.type == 11")"
printf "    %-22s %s\n" "packets on core link" "$(count "$CAP_DIR/scenario-14-core.pcapng" "ip")"

info "Captures written:"
ls -lh "$CAP_DIR"/scenario-14*.pcapng
