#!/usr/bin/env bash
# =============================================================
#  Scenario 30 - "Quiet, regular and suspicious"
#  What you see: among normal office traffic, one PC contacts the same outside server on a
#          fixed timer, every 5 seconds to within a few milliseconds (a "beacon"), and asks
#          the DNS server about long, random-looking names under one domain, about once a
#          second. Regular timing and odd DNS names are two classic signs of malware
#          calling home and of data being smuggled out inside DNS queries ("DNS tunnelling").
#  Output: captures/scenario-30.pcapng   at the office switch, about 60 seconds
#  Usage : cd ~/wireshark-lab && sudo ./scenarios/s30.sh
#  Note  : the lab only imitates the traffic pattern. The "beacon" fetches a tiny page from
#          a lab web server, and the DNS names are random bytes, not data from anywhere.
#          Real beacons often wait a minute or more; the lab uses 5 seconds to stay short.
# =============================================================
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
require_root
trap cleanup EXIT
need dnsmasq dnsmasq-base
need dig bind9-dnsutils

SW=s30-sw
PC=s30-pc         # Karan's PC, 10.73.1.20: normal work
INF=s30-inf       # the infected PC, 10.73.1.23
DNS=s30-dns       # office DNS server, 10.73.1.53
RTR=s30-rtr       # office router, 10.73.1.1 / 10.73.2.1
NET=s30-net       # "the internet": web servers 10.73.2.50 and 10.73.2.80

info "Building topology:  two PCs and the DNS server on a switch (with a monitor port), router, outside servers"
switch_add $SW
for n in $PC $INF $DNS $RTR $NET; do ns_add $n; done
no_ipv6 $PC $INF $DNS $RTR $NET
switch_port $SW $PC  eth0 02:00:0a:49:01:14
switch_port $SW $INF eth0 02:00:0a:49:01:17
switch_port $SW $DNS eth0 02:00:0a:49:01:35
switch_port $SW $RTR eth0 02:00:0a:49:01:01
veth $RTR eth1 02:00:0a:49:02:01   $NET eth0 02:00:0a:49:02:50
addr $PC  eth0 10.73.1.20/24 ;  gw $PC  10.73.1.1
addr $INF eth0 10.73.1.23/24 ;  gw $INF 10.73.1.1
addr $DNS eth0 10.73.1.53/24 ;  gw $DNS 10.73.1.1
addr $RTR eth0 10.73.1.1/24  ;  addr $RTR eth1 10.73.2.1/24 ;  router $RTR
addr $NET eth0 10.73.2.50/24 ;  ip -n $NET addr add 10.73.2.80/24 dev eth0 ;  gw $NET 10.73.2.1
tc -n $RTR qdisc replace dev eth1 root netem delay 15ms
switch_span $SW

info "Starting the outside web servers and the office DNS server"
web_server $NET 0.0.0.0 "www.news.lab docs.vendor.lab update-cdn.lab"
head -c 20000 /dev/urandom | base64 > "$RUN_DIR/www/index.html"
echo ok > "$RUN_DIR/www/c"
chmod -R a+rX "$RUN_DIR/www"
dns_server $DNS 10.73.1.53 dns --local-ttl=60 \
  --host-record=www.news.lab,10.73.2.80 --host-record=docs.vendor.lab,10.73.2.80 \
  --host-record=update-cdn.lab,10.73.2.50 --local=/news.lab/ --local=/vendor.lab/ \
  --local=/update-cdn.lab/ --local=/sync-cdn.lab/
resolver $PC  "nameserver 10.73.1.53"
resolver $INF "nameserver 10.73.1.53"

# Karan: opens a page now and then, at irregular moments
karan() {
  local end=$((SECONDS + 58)) sites=(www.news.lab docs.vendor.lab www.news.lab)
  while (( SECONDS < end )); do
    ip netns exec $PC curl --noproxy "*" -s -o /dev/null --max-time 3 "http://${sites[RANDOM % 3]}/?r=$RANDOM" || true
    sleep "$(( 1 + RANDOM % 6 )).$(( RANDOM % 10 ))"
  done
}
# the beacon: a tiny request every 5 seconds, on the clock
beacon() {
  local t0; t0=$(date +%s.%N)
  for i in $(seq 0 11); do
    ip netns exec $INF curl --noproxy "*" -s -o /dev/null --max-time 2 "http://update-cdn.lab/c?id=7f3a91&n=$i" || true
    sleep "$(awk -v t0="$t0" -v i="$i" -v now="$(date +%s.%N)" 'BEGIN { s = t0 + 5*(i+1) - now; if (s < 0) s = 0; printf "%.3f", s }')"
  done
}
# the tunnel imitation: a TXT query about once a second, for a long random name
tunnel() {
  local end=$((SECONDS + 55)) n=0 chunk
  while (( SECONDS < end )); do
    chunk=$(head -c 30 /dev/urandom | od -An -tx1 | tr -d ' \n')
    ip netns exec $INF dig +short +tries=1 +time=1 @10.73.1.53 TXT "${chunk:0:60}.$n.t.sync-cdn.lab" >/dev/null 2>&1 || true
    n=$((n + 1))
    sleep 1
  done
}

info "Capturing about 60 seconds at the office switch"
capture_start $SW span0 "$CAP_DIR/scenario-30.pcapng"
karan & K=$!
sleep 2
beacon & B=$!
sleep 1
tunnel & T=$!
wait $K $B $T 2>/dev/null || true
sleep 1
capture_stop ; capture_check "$CAP_DIR/scenario-30.pcapng"

printf "    %-24s %s\n" "beacon requests" "$(count "$CAP_DIR/scenario-30.pcapng" "http.request && ip.src == 10.73.1.23")"
printf "    %-24s %s\n" "beacon spacing (s)" \
  "$(tshark -r "$CAP_DIR/scenario-30.pcapng" -Y "http.request && ip.src == 10.73.1.23" -T fields -e frame.time_relative 2>/dev/null | awk 'NR>1 {d=$1-p; printf "%.3f ", d} {p=$1}')"
printf "    %-24s %s\n" "Karan's requests" "$(count "$CAP_DIR/scenario-30.pcapng" "http.request && ip.src == 10.73.1.20")"
printf "    %-24s %s\n" "long DNS names (>50)" "$(count "$CAP_DIR/scenario-30.pcapng" "dns.flags.response == 0 && dns.qry.name.len > 50")"

info "Captures written:"
ls -lh "$CAP_DIR"/scenario-30*.pcapng
