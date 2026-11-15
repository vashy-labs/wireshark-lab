#!/usr/bin/env bash
# =============================================================
#  Scenario 07 - "A fast link that will not go fast"
#  Fault : TCP window scaling is switched off on the receiving machine.
#          Its receive window can never exceed 65,535 bytes, and on a path
#          with a 100 ms round trip that caps the transfer at about 5 Mbit/s,
#          however fast the line is.
#  Output: captures/scenario-07.pcapng           (window scaling off: the problem)
#          captures/scenario-07-baseline.pcapng  (window scaling on)
#  Usage : cd ~/wireshark-lab && sudo ./scenarios/s07.sh
# =============================================================
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
require_root
trap cleanup EXIT

PC=s07-bkp        # the backup server at head office: it pulls the file
RTR=s07-wan
SRV=s07-srv       # the file server in the branch
SERVER_IP=10.70.2.20
SITE=files.branch.lab.local
FILE=nightly-archive.tar
FILE_MB=8
WAN="delay 50ms rate 50mbit limit 3000"   # ~100 ms round trip, 50 Mbit/s

info "Building topology:  backup server 10.70.1.10 --- WAN --- branch file server 10.70.2.20"
ns_add $PC
ns_add $RTR
ns_add $SRV
veth $PC  eth0 02:00:0a:46:01:0a   $RTR eth0 02:00:0a:46:01:01
veth $RTR eth1 02:00:0a:46:02:01   $SRV eth0 02:00:0a:46:02:14
addr $PC  eth0 10.70.1.10/24 ;  gw $PC 10.70.1.1
addr $RTR eth0 10.70.1.1/24  ;  addr $RTR eth1 10.70.2.1/24 ;  router $RTR
addr $SRV eth0 10.70.2.20/24 ;  gw $SRV 10.70.2.1
tc -n $RTR qdisc replace dev eth0 root netem $WAN   # towards the backup server
tc -n $RTR qdisc replace dev eth1 root netem $WAN   # towards the file server

info "Starting the file server with a ${FILE_MB} MB file"
web_server $SRV $SERVER_IP $SITE
head -c $((FILE_MB * 1024 * 1024)) /dev/urandom > "$RUN_DIR/www/$FILE"
chmod -R a+rX "$RUN_DIR/www"

# run <capture-file> <window scaling on the backup server: 1 or 0>
run() {
  local out=$1 r
  ip netns exec $PC sysctl -qw net.ipv4.tcp_window_scaling=$2
  ip netns exec $PC  ip tcp_metrics flush >/dev/null 2>&1 || true
  ip netns exec $SRV ip tcp_metrics flush >/dev/null 2>&1 || true
  ip netns exec $PC ping -c 1 -W 3 $SERVER_IP >/dev/null 2>&1 || true   # resolve ARP before capturing
  capture_start $PC eth0 "$out"
  r=$(ip netns exec $PC curl -s --max-time 300 -o /dev/null --resolve "$SITE:80:$SERVER_IP" \
        -w '%{time_total} %{speed_download}' "http://$SITE/$FILE") \
    || { echo "!! download failed"; return 1; }
  capture_stop
  capture_check "$out"
  awk -v r="$r" 'BEGIN { split(r, a, " ");
    printf "    download time          %.1f s\n    average speed          %.1f Mbit/s\n", a[1], a[2] * 8 / 1000000 }'
  printf "    %-22s %s\n" "window scale in SYNs" \
    "$(tshark -r "$out" -Y "tcp.flags.syn==1" -T fields -e tcp.options.wscale.shift 2>/dev/null \
        | awk '{ print ($1 == "" ? "none" : $1) }' | paste -sd, - )"
  printf "    %-22s %s bytes\n" "largest window (bkp)" \
    "$(tshark -r "$out" -Y "ip.src==10.70.1.10 && tcp.flags.syn==0" -T fields -e tcp.window_size 2>/dev/null | sort -n | tail -1)"
  tcp_stats "$out"
  printf "    %-22s %s\n" "window_full" "$(tshark -r "$out" -Y "tcp.analysis.window_full" 2>/dev/null | wc -l)"
}

info "Run 1/2: window scaling on (baseline)"
run "$CAP_DIR/scenario-07-baseline.pcapng" 1

info "Run 2/2: window scaling off on the backup server (the problem)"
run "$CAP_DIR/scenario-07.pcapng" 0

info "Captures written:"
ls -lh "$CAP_DIR"/scenario-07*.pcapng
