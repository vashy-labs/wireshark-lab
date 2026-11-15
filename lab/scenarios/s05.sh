#!/usr/bin/env bash
# =============================================================
#  Scenario 05 - "Small pages load, big pages hang"
#  Fault : an MTU black hole. One link on the path carries at most 1400-byte
#          packets, and the ICMP "fragmentation needed" messages that should
#          tell the server so are thrown away. Small packets pass, full-size
#          packets vanish.
#  Output: captures/scenario-05.pcapng           PC side: small page loads, big page hangs
#          captures/scenario-05-server.pcapng    the same moment, captured on the server
#          captures/scenario-05-fixed.pcapng     server side, ICMP allowed again: the server adapts
#          captures/scenario-05-baseline.pcapng  PC side, no small link: both pages load
#  Usage : cd ~/wireshark-lab && sudo ./scenarios/s05.sh
# =============================================================
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
require_root
trap cleanup EXIT

PC=s05-pc
R1=s05-r1         # branch router
R2=s05-r2         # head-office router
SRV=s05-srv
SERVER_IP=10.50.2.20
SITE=wiki.lab.local

info "Building topology:  PC 10.50.1.10 --- R1 === tunnel link === R2 --- web server 10.50.2.20"
ns_add $PC
ns_add $R1
ns_add $R2
ns_add $SRV
veth $PC eth0 02:00:0a:32:01:0a   $R1  eth0 02:00:0a:32:01:01
veth $R1 eth1 02:00:0a:32:09:01   $R2  eth0 02:00:0a:32:09:02
veth $R2 eth1 02:00:0a:32:02:01   $SRV eth0 02:00:0a:32:02:14
addr $PC  eth0 10.50.1.10/24 ;  gw $PC 10.50.1.1
addr $R1  eth0 10.50.1.1/24  ;  addr $R1 eth1 10.50.9.1/30 ;  router $R1
addr $R2  eth0 10.50.9.2/30  ;  addr $R2 eth1 10.50.2.1/24 ;  router $R2
addr $SRV eth0 10.50.2.20/24 ;  gw $SRV 10.50.2.1
ip -n $R1 route add 10.50.2.0/24 via 10.50.9.2
ip -n $R2 route add 10.50.1.0/24 via 10.50.9.1
tc -n $R1 qdisc replace dev eth1 root netem delay 10ms rate 50mbit
tc -n $R2 qdisc replace dev eth0 root netem delay 10ms rate 50mbit

info "Starting the web server (one small page, one big page)"
web_server $SRV $SERVER_IP $SITE
head -c 900   /dev/urandom > "$RUN_DIR/www/status.html"
head -c 48000 /dev/urandom > "$RUN_DIR/www/handbook.html"
chmod -R a+rX "$RUN_DIR/www"

link_mtu() {          # set the MTU of the R1 === R2 link
  ip -n $R1 link set eth1 mtu "$1"
  ip -n $R2 link set eth0 mtu "$1"
}
fetch() {             # fetch <page> <seconds to wait>  ->  prints one result line
  local r rc=0
  r=$(ip netns exec $PC curl -s -o /dev/null --max-time "$2" --resolve "$SITE:80:$SERVER_IP" \
        -w '%{http_code} %{size_download} %{time_total}' "http://$SITE/$1") || rc=$?
  awk -v p="$1" -v r="$r" -v rc="$rc" 'BEGIN { split(r, a, " ");
    printf "    %-22s HTTP %s, %s bytes, %.2f s, curl exit code %s\n", p, a[1], a[2], a[3], rc }'
}
forget() {            # make every machine forget what it learned about the path
  local ns
  for ns in $PC $R1 $R2 $SRV; do
    ip netns exec $ns ip route flush cache >/dev/null 2>&1 || true
    ip netns exec $ns ip tcp_metrics flush >/dev/null 2>&1 || true
  done
  ip netns exec $PC ping -c 1 -W 2 $SERVER_IP >/dev/null 2>&1 || true
}
report() {            # report <capture>
  printf "    %-22s %s\n" "retransmissions"      "$(count "$1" "tcp.analysis.retransmission")"
  printf "    %-22s %s\n" "ICMP frag. needed"    "$(count "$1" "icmp.type==3 && icmp.code==4")"
  printf "    %-22s %s\n" "largest frame (bytes)" \
    "$(tshark -r "$1" -Y "tcp" -T fields -e frame.len 2>/dev/null | sort -n | tail -1)"
}

info "Run 1/3: every link carries 1500-byte packets (baseline, PC side)"
link_mtu 1500 ; forget
capture_start $PC eth0 "$CAP_DIR/scenario-05-baseline.pcapng"
fetch status.html 10
fetch handbook.html 10
capture_stop ; capture_check "$CAP_DIR/scenario-05-baseline.pcapng"
report "$CAP_DIR/scenario-05-baseline.pcapng"

info "Run 2/3: tunnel link carries only 1400 bytes, ICMP messages are dropped (the problem)"
link_mtu 1400
ip netns exec $R2 iptables -A OUTPUT -p icmp --icmp-type fragmentation-needed -j DROP
forget
capture2_start $SRV eth0 "$CAP_DIR/scenario-05-server.pcapng"
capture_start  $PC  eth0 "$CAP_DIR/scenario-05.pcapng"
fetch status.html 10
fetch handbook.html 14
capture_stop ; capture2_stop
capture_check "$CAP_DIR/scenario-05.pcapng" ; capture_check "$CAP_DIR/scenario-05-server.pcapng"
echo "    PC side:" ;     report "$CAP_DIR/scenario-05.pcapng"
echo "    server side:" ; report "$CAP_DIR/scenario-05-server.pcapng"

info "Run 3/3: same small link, ICMP messages allowed again (fixed, server side)"
ip netns exec $R2 iptables -F OUTPUT
sleep 2 ; forget
capture_start $SRV eth0 "$CAP_DIR/scenario-05-fixed.pcapng"
fetch status.html 10
fetch handbook.html 14
capture_stop ; capture_check "$CAP_DIR/scenario-05-fixed.pcapng"
report "$CAP_DIR/scenario-05-fixed.pcapng"

info "Captures written:"
ls -lh "$CAP_DIR"/scenario-05*.pcapng
