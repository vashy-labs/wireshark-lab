#!/usr/bin/env bash
# =============================================================
#  Scenario 16 - "Half the office lost the intranet"
#  Fault : the intranet moved from 10.160.2.20 to a new server, 10.160.2.30. The record
#          was changed on DNS1 but not on DNS2. PCs that ask DNS2 first are sent to
#          the old address, where nothing answers any more.
#  Output: captures/scenario-16.pcapng           a PC that asks DNS2 first: wrong address
#          captures/scenario-16-baseline.pcapng  a PC that asks DNS1 first: page loads
#          captures/scenario-16-compare.pcapng   the same question put to both DNS servers
#  Usage : cd ~/wireshark-lab && sudo ./scenarios/s16.sh
# =============================================================
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
require_root
trap cleanup EXIT
need dnsmasq dnsmasq-base
need dig bind9-dnsutils

SW=s16-sw
PC=s16-pc
DNS1=s16-dns1     # 10.160.1.53, updated
DNS2=s16-dns2     # 10.160.1.54, forgotten
RTR=s16-rtr
SRV=s16-new       # the new intranet server, 10.160.2.30
SITE=intranet.lab.local

info "Building topology:  PC and two DNS servers on one switch, router, new intranet server behind it"
switch_add $SW
ns_add $PC
ns_add $DNS1
ns_add $DNS2
ns_add $RTR
ns_add $SRV
no_ipv6 $PC $DNS1 $DNS2 $RTR $SRV
switch_port $SW $PC   eth0 02:00:0a:a0:01:0a
switch_port $SW $DNS1 eth0 02:00:0a:a0:01:35
switch_port $SW $DNS2 eth0 02:00:0a:a0:01:36
switch_port $SW $RTR  eth0 02:00:0a:a0:01:01
veth $RTR eth1 02:00:0a:a0:02:01   $SRV eth0 02:00:0a:a0:02:1e
addr $PC   eth0 10.160.1.10/24 ;  gw $PC   10.160.1.1
addr $DNS1 eth0 10.160.1.53/24 ;  gw $DNS1 10.160.1.1
addr $DNS2 eth0 10.160.1.54/24 ;  gw $DNS2 10.160.1.1
addr $RTR  eth0 10.160.1.1/24  ;  addr $RTR eth1 10.160.2.1/24 ;  router $RTR
addr $SRV  eth0 10.160.2.30/24 ;  gw $SRV  10.160.2.1
tc -n $PC qdisc replace dev eth0 root netem delay 1ms

info "Starting the new intranet server and both DNS servers"
web_server $SRV 10.160.2.30 $SITE
head -c 5000 /dev/urandom > "$RUN_DIR/www/index.html"
chmod -R a+rX "$RUN_DIR/www"
dns_server $DNS1 10.160.1.53 dns1 --host-record=$SITE,10.160.2.30 --local-ttl=3600
dns_server $DNS2 10.160.1.54 dns2 --host-record=$SITE,10.160.2.20 --local-ttl=3600   # never updated

# open_intranet  - open the intranet by name, as a browser would
open_intranet() {
  local r rc=0
  r=$(ip netns exec $PC curl -s -o /dev/null --connect-timeout 10 \
        -w '%{http_code}|%{remote_ip}|%{time_total}' "http://$SITE/") || rc=$?
  awk -v r="$r" -v rc="$rc" 'BEGIN { split(r, a, "|");
    printf "    intranet (browser)     HTTP %s, connected to %s, after %.1f s%s\n",
      a[1], (a[2] == "" ? "nothing" : a[2]), a[3], (rc != 0 ? ", curl exit code " rc : "") }'
  sleep 1
}

info "Run 1/3: a PC on the first floor - its DNS servers are DNS1, then DNS2 (baseline)"
resolver $PC "nameserver 10.160.1.53" "nameserver 10.160.1.54"
capture_start $PC eth0 "$CAP_DIR/scenario-16-baseline.pcapng"
open_intranet
capture_stop ; capture_check "$CAP_DIR/scenario-16-baseline.pcapng"

info "Run 2/3: a PC on the second floor - its DNS servers are DNS2, then DNS1 (the problem)"
resolver $PC "nameserver 10.160.1.54" "nameserver 10.160.1.53"
ip -n $RTR neigh flush all
capture_start $PC eth0 "$CAP_DIR/scenario-16.pcapng"
open_intranet
capture_stop ; capture_check "$CAP_DIR/scenario-16.pcapng"
printf "    %-22s %s\n" "DNS answer" \
  "$(tshark -r "$CAP_DIR/scenario-16.pcapng" -Y "dns.flags.response == 1 && dns.a" -T fields -e ip.src -e dns.a 2>/dev/null | awk '{print $2 " (from " $1 ")"}' | paste -sd, -)"
printf "    %-22s %s\n" "SYNs sent" "$(count "$CAP_DIR/scenario-16.pcapng" "tcp.flags.syn == 1 && tcp.flags.ack == 0 && !icmp")"
printf "    %-22s %s\n" "ICMP unreachable" "$(count "$CAP_DIR/scenario-16.pcapng" "icmp.type == 3")"

info "Run 3/3: the network team asks both DNS servers the same question"
capture_start $PC eth0 "$CAP_DIR/scenario-16-compare.pcapng"
for s in 10.160.1.53 10.160.1.54; do
  printf "    %-22s %s\n" "dig @$s" "$(ip netns exec $PC dig +short +tries=1 +time=3 @$s $SITE A | paste -sd, -)"
  sleep 1
done
capture_stop ; capture_check "$CAP_DIR/scenario-16-compare.pcapng"

info "Captures written:"
ls -lh "$CAP_DIR"/scenario-16*.pcapng
