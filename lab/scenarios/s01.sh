#!/usr/bin/env bash
# =============================================================
#  Scenario 01 - "The download that crawls"
#  Fault : random packet loss on the WAN link (server -> PC direction)
#  Output: captures/scenario-01.pcapng           (the problem)
#          captures/scenario-01-baseline.pcapng  (same download, healthy link)
#  Usage : cd ~/wireshark-lab && sudo ./scenarios/s01.sh
# =============================================================
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
require_root
trap cleanup EXIT

PC=s01-pc
RTR=s01-wan
SRV=s01-srv
SERVER_IP=10.10.2.20
FILE=monthly-report.zip
FILE_MB=5
WAN="delay 25ms rate 20mbit"   # each direction -> ~50 ms RTT on a 20 Mbit/s link
FAULT="loss 2%"                # the problem we are injecting

info "Building topology:  PC 10.10.1.10 --- WAN router --- file server 10.10.2.20"
ns_add $PC
ns_add $RTR
ns_add $SRV
veth $PC  eth0 02:00:0a:0a:01:0a   $RTR eth0 02:00:0a:0a:01:01
veth $RTR eth1 02:00:0a:0a:02:01   $SRV eth0 02:00:0a:0a:02:14
addr $PC  eth0 10.10.1.10/24 ;  gw $PC 10.10.1.1
addr $RTR eth0 10.10.1.1/24  ;  addr $RTR eth1 10.10.2.1/24 ;  router $RTR
addr $SRV eth0 10.10.2.20/24 ;  gw $SRV 10.10.2.1

info "Starting file server with a ${FILE_MB} MB file"
web_server $SRV $SERVER_IP files.lab.local
head -c $((FILE_MB * 1024 * 1024)) /dev/urandom > "$RUN_DIR/www/$FILE"
chmod 644 "$RUN_DIR/www/$FILE"

# download <capture-file> <extra netem options>
download() {
  local out=$1 extra=$2 r
  tc -n $RTR qdisc replace dev eth0 root netem $WAN $extra   # towards the PC
  tc -n $RTR qdisc replace dev eth1 root netem $WAN          # towards the server
  capture_start $PC eth0 "$out"
  r=$(ip netns exec $PC curl -s --max-time 300 -o /dev/null \
        -w '%{time_total} %{speed_download}' "http://$SERVER_IP/$FILE")
  capture_stop
  capture_check "$out"
  awk -v r="$r" 'BEGIN { split(r, a, " "); printf "    download time %.1f s, speed %.0f KB/s\n", a[1], a[2]/1024 }'
  tcp_stats "$out"
}

info "Run 1/2: healthy link (baseline)"
download "$CAP_DIR/scenario-01-baseline.pcapng" ""

info "Run 2/2: same download, with the fault ($FAULT)"
download "$CAP_DIR/scenario-01.pcapng" "$FAULT"

info "Captures written:"
ls -lh "$CAP_DIR"/scenario-01*.pcapng
