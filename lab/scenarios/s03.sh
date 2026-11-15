#!/usr/bin/env bash
# =============================================================
#  Scenario 03 - "The transfer that keeps stopping"
#  Fault : a slow receiver. The application on the PC reads its data slowly
#          (and freezes once for 4 seconds), so the PC's TCP window fills up
#          and it tells the server to stop: zero window.
#  Output: captures/scenario-03.pcapng           (the slow PC: the problem)
#          captures/scenario-03-baseline.pcapng  (same download, application reads at full speed)
#  Usage : cd ~/wireshark-lab && sudo ./scenarios/s03.sh
# =============================================================
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
require_root
trap cleanup EXIT

PC=s03-pc
RTR=s03-core
SRV=s03-srv
SERVER_IP=10.30.2.20
SITE=reports.lab.local
FILE=sales-report-q3.pdf
FILE_MB=3
LAN="delay 1ms rate 100mbit"   # same building: ~2 ms round trip, 100 Mbit/s

info "Building topology:  PC 10.30.1.10 --- core switch/router --- report server 10.30.2.20"
ns_add $PC
ns_add $RTR
ns_add $SRV
veth $PC  eth0 02:00:0a:1e:01:0a   $RTR eth0 02:00:0a:1e:01:01
veth $RTR eth1 02:00:0a:1e:02:01   $SRV eth0 02:00:0a:1e:02:14
addr $PC  eth0 10.30.1.10/24 ;  gw $PC 10.30.1.1
addr $RTR eth0 10.30.1.1/24  ;  addr $RTR eth1 10.30.2.1/24 ;  router $RTR
addr $SRV eth0 10.30.2.20/24 ;  gw $SRV 10.30.2.1
tc -n $RTR qdisc replace dev eth0 root netem $LAN   # towards the PC
tc -n $RTR qdisc replace dev eth1 root netem $LAN   # towards the server

info "Starting the report server with a ${FILE_MB} MB file"
web_server $SRV $SERVER_IP $SITE
head -c $((FILE_MB * 1024 * 1024)) /dev/urandom > "$RUN_DIR/www/$FILE"
chmod -R a+rX "$RUN_DIR/www"

# The "report viewer" on the PC: it downloads the file and handles it block by block.
#   args: server-ip  path  block-bytes  seconds-per-block  freeze-after-bytes  freeze-seconds
cat > "$RUN_DIR/viewer.py" <<'EOF'
import socket, sys, time
host, path = sys.argv[1], sys.argv[2]
block, per_block = int(sys.argv[3]), float(sys.argv[4])
freeze_after, freeze = int(sys.argv[5]), float(sys.argv[6])
s = socket.create_connection((host, 80))
request = ("GET /%s HTTP/1.1\r\nHost: reports.lab.local\r\n"
           "User-Agent: ReportViewer/2.1\r\nConnection: close\r\n\r\n" % path)
s.sendall(request.encode())
total, frozen = 0, False
while True:
    data = s.recv(block)
    if not data:
        break
    total += len(data)
    if per_block:
        time.sleep(per_block)            # "processing" the block
    if freeze and not frozen and total >= freeze_after:
        frozen = True
        time.sleep(freeze)               # the application hangs for a moment
s.close()
EOF

# run <capture-file> <block-bytes> <seconds-per-block> <freeze-after-bytes> <freeze-seconds>
run() {
  local out=$1 t0 t1 k
  ip netns exec $PC  ip tcp_metrics flush >/dev/null 2>&1 || true
  ip netns exec $SRV ip tcp_metrics flush >/dev/null 2>&1 || true
  ip netns exec $PC ping -c 1 -W 3 $SERVER_IP >/dev/null 2>&1 || true   # resolve ARP before capturing
  capture_start $PC eth0 "$out"
  t0=$(date +%s.%N)
  ip netns exec $PC python3 "$RUN_DIR/viewer.py" $SERVER_IP "$FILE" "$2" "$3" "$4" "$5" \
    || { echo "!! download failed"; return 1; }
  t1=$(date +%s.%N)
  capture_stop
  capture_check "$out"
  awk -v a="$t0" -v b="$t1" 'BEGIN { printf "    download time          %.1f s\n", b - a }'
  tcp_stats "$out"
  for k in window_full window_update zero_window_probe zero_window_probe_ack keep_alive keep_alive_ack; do
    printf "    %-22s %s\n" "$k" "$(tshark -r "$out" -Y "tcp.analysis.$k" 2>/dev/null | wc -l)"
  done
}

info "Run 1/2: a healthy PC, application reads at full speed (baseline)"
run "$CAP_DIR/scenario-03-baseline.pcapng" 65536 0 0 0

info "Run 2/2: the slow PC, 16 KB every 0.1 s and one 4-second freeze (the problem)"
run "$CAP_DIR/scenario-03.pcapng" 16384 0.1 1048576 4

info "Captures written:"
ls -lh "$CAP_DIR"/scenario-03*.pcapng
