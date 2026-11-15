#!/usr/bin/env bash
# =============================================================
#  Scenario 13 - "Ping works, the website does not"
#  Fault : a firewall between the PC and the web server blocks TCP port 80.
#          The same block is captured in the three ways a firewall can do it,
#          plus two captures to compare with.
#  Output: captures/scenario-13.pcapng           firewall silently DROPS (the problem in the ticket)
#          captures/scenario-13-reject.pcapng    firewall rejects with an ICMP message
#          captures/scenario-13-reset.pcapng     firewall rejects with a forged TCP reset
#          captures/scenario-13-closed.pcapng    no firewall rule; the web service itself is stopped
#          captures/scenario-13-baseline.pcapng  everything works
#  Usage : cd ~/wireshark-lab && sudo ./scenarios/s13.sh
# =============================================================
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
require_root
trap cleanup EXIT

PC=s13-pc
FW=s13-fw
SRV=s13-srv
SERVER_IP=10.130.2.20
SITE=intranet.lab.local
LINK="delay 5ms rate 100mbit"   # ~10 ms round trip

info "Building topology:  PC 10.130.1.10 --- firewall --- web server 10.130.2.20"
ns_add $PC
ns_add $FW
ns_add $SRV
veth $PC eth0 02:00:0a:82:01:0a   $FW  eth0 02:00:0a:82:01:01
veth $FW eth1 02:00:0a:82:02:01   $SRV eth0 02:00:0a:82:02:14
addr $PC  eth0 10.130.1.10/24 ;  gw $PC 10.130.1.1
addr $FW  eth0 10.130.1.1/24  ;  addr $FW eth1 10.130.2.1/24 ;  router $FW
addr $SRV eth0 10.130.2.20/24 ;  gw $SRV 10.130.2.1
tc -n $FW qdisc replace dev eth0 root netem $LINK   # towards the PC
tc -n $FW qdisc replace dev eth1 root netem $LINK   # towards the server

info "Starting the web server"
web_server $SRV $SERVER_IP $SITE
head -c 4200 /dev/urandom > "$RUN_DIR/www/index.html"
chmod -R a+rX "$RUN_DIR/www"

fw() { ip netns exec $FW iptables "$@"; }

# run <capture-file> <label>
#   The user first pings the server, then opens the site.
run() {
  local out=$1 r rc=0
  ip netns exec $PC ping -c 1 -W 2 10.130.1.1 >/dev/null 2>&1 || true    # resolve ARP before capturing
  capture_start $PC eth0 "$out"
  ip netns exec $PC ping -c 2 -i 0.3 -W 2 $SERVER_IP >/dev/null 2>&1 \
    && echo "    ping                   works" || echo "    ping                   FAILS"
  r=$(ip netns exec $PC curl -s -o /dev/null --connect-timeout 16 --max-time 20 \
        --resolve "$SITE:80:$SERVER_IP" -w '%{http_code} %{time_total}' "http://$SITE/") || rc=$?
  sleep 0.5
  capture_stop
  capture_check "$out"
  awk -v r="$r" -v rc="$rc" 'BEGIN { split(r, a, " ");
    printf "    browser (curl)         HTTP %s, exit code %s, after %.2f s\n", a[1], rc, a[2] }'
  printf "    %-22s %s\n" "SYNs sent" \
    "$(tshark -r "$out" -Y "tcp.flags.syn==1 && tcp.flags.ack==0" 2>/dev/null | wc -l)"
  printf "    %-22s %s\n" "TCP resets (TTL)" \
    "$(tshark -r "$out" -Y "tcp.flags.reset==1" -T fields -e ip.ttl 2>/dev/null | paste -sd, - | sed 's/^$/none/')"
  printf "    %-22s %s\n" "ICMP unreachable" \
    "$(tshark -r "$out" -Y "icmp.type==3" -T fields -e ip.src -e icmp.code 2>/dev/null \
        | awk '{ print "from " $1 " code " $2 }' | paste -sd';' - | sed 's/^$/none/')"
  printf "    %-22s %s\n" "TTL of server packets" \
    "$(tshark -r "$out" -Y "ip.src==$SERVER_IP && icmp.type==0" -T fields -e ip.ttl 2>/dev/null | sort -u | paste -sd, - | sed 's/^$/-/')"
}

info "Run 1/5: no block, everything works (baseline)"
run "$CAP_DIR/scenario-13-baseline.pcapng"

info "Run 2/5: firewall silently drops TCP 80 (the problem)"
fw -A FORWARD -p tcp --dport 80 -j DROP
run "$CAP_DIR/scenario-13.pcapng"
fw -F FORWARD

info "Run 3/5: firewall rejects TCP 80 with an ICMP message"
fw -A FORWARD -p tcp --dport 80 -j REJECT --reject-with icmp-admin-prohibited
run "$CAP_DIR/scenario-13-reject.pcapng"
fw -F FORWARD

info "Run 4/5: firewall rejects TCP 80 with a TCP reset"
fw -A FORWARD -p tcp --dport 80 -j REJECT --reject-with tcp-reset
run "$CAP_DIR/scenario-13-reset.pcapng"
fw -F FORWARD

info "Run 5/5: no firewall rule, but the web service is stopped"
ip netns pids $SRV | xargs -r kill 2>/dev/null || true
sleep 1
run "$CAP_DIR/scenario-13-closed.pcapng"

info "Captures written:"
ls -lh "$CAP_DIR"/scenario-13*.pcapng
