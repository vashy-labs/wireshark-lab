#!/usr/bin/env bash
# =============================================================
#  Scenario 04 - "The network is slow - or is it?"
#  Fault : a slow application. One request (the customer search) makes the
#          server think for about 4 seconds. The network is fast and clean.
#  Output: captures/scenario-04.pcapng           (the slow search: the problem)
#          captures/scenario-04-baseline.pcapng  (the same clicks on a good day)
#  Usage : cd ~/wireshark-lab && sudo ./scenarios/s04.sh
# =============================================================
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
require_root
trap cleanup EXIT

PC=s04-pc
RTR=s04-wan
SRV=s04-srv
SERVER_IP=10.40.2.20
SITE=crm.lab.local
LINK="delay 10ms rate 100mbit"   # ~20 ms round trip, 100 Mbit/s

info "Building topology:  PC 10.40.1.10 --- router --- CRM server 10.40.2.20"
ns_add $PC
ns_add $RTR
ns_add $SRV
veth $PC  eth0 02:00:0a:28:01:0a   $RTR eth0 02:00:0a:28:01:01
veth $RTR eth1 02:00:0a:28:02:01   $SRV eth0 02:00:0a:28:02:14
addr $PC  eth0 10.40.1.10/24 ;  gw $PC 10.40.1.1
addr $RTR eth0 10.40.1.1/24  ;  addr $RTR eth1 10.40.2.1/24 ;  router $RTR
addr $SRV eth0 10.40.2.20/24 ;  gw $SRV 10.40.2.1
tc -n $RTR qdisc replace dev eth0 root netem $LINK   # towards the PC
tc -n $RTR qdisc replace dev eth1 root netem $LINK   # towards the server

# The CRM application: a small web server. Every request is answered at once,
# except the customer search, which waits for its "database" first. The wait
# (in seconds) is read from a file, so it can be changed between the two runs.
cat > "$RUN_DIR/crm.py" <<'EOF'
import os, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DELAY_FILE = sys.argv[2]
random_bytes = os.urandom(64 * 1024)
SIZES = {"/crm/": 5200, "/crm/app.js": 14800, "/crm/style.css": 6100,
         "/crm/api/user": 640, "/crm/api/search": 18300, "/crm/api/customer/1042": 2900}

class Crm(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "CRM-App/3.4"
    sys_version = ""
    wbufsize = 65536          # send headers and body together, in one write

    def do_GET(self):
        path = self.path.split("?")[0]
        if path not in SIZES:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            self.wfile.flush()
            return
        if path == "/crm/api/search":
            with open(DELAY_FILE) as f:
                time.sleep(float(f.read().strip()))      # the database query
        body = random_bytes[:SIZES[path]]
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()

    def log_message(self, *args):
        pass

ThreadingHTTPServer((sys.argv[1], 80), Crm).serve_forever()
EOF

info "Starting the CRM application"
echo "0.08" > "$RUN_DIR/search-delay"
ip netns exec $SRV python3 "$RUN_DIR/crm.py" $SERVER_IP "$RUN_DIR/search-delay" &
sleep 1.5

# What the user does: open the CRM, search for a customer, open the record.
URLS=(
  "http://$SITE/crm/"
  "http://$SITE/crm/style.css"
  "http://$SITE/crm/app.js"
  "http://$SITE/crm/api/user"
  "http://$SITE/crm/api/search?name=sharma&city=pune"
  "http://$SITE/crm/api/customer/1042"
)

# run <capture-file> <search delay in seconds>
run() {
  local out=$1 url args=() t0 t1
  echo "$2" > "$RUN_DIR/search-delay"
  ip netns exec $PC  ip tcp_metrics flush >/dev/null 2>&1 || true
  ip netns exec $SRV ip tcp_metrics flush >/dev/null 2>&1 || true
  ip netns exec $PC ping -c 1 -W 3 $SERVER_IP >/dev/null 2>&1 || true   # resolve ARP before capturing
  for url in "${URLS[@]}"; do args+=(-o /dev/null "$url"); done
  capture_start $PC eth0 "$out"
  t0=$(date +%s.%N)
  ip netns exec $PC curl -s --max-time 60 --resolve "$SITE:80:$SERVER_IP" "${args[@]}" \
    || { echo "!! requests failed"; return 1; }
  t1=$(date +%s.%N)
  capture_stop
  capture_check "$out"
  awk -v a="$t0" -v b="$t1" 'BEGIN { printf "    total time             %.2f s\n", b - a }'
  printf "    %-22s %s ms\n" "handshake round trip" \
    "$(tshark -r "$out" -Y "tcp.flags.syn==1 && tcp.flags.ack==1" -T fields -e tcp.analysis.ack_rtt 2>/dev/null \
        | head -1 | awk '{ printf "%.1f", $1 * 1000 }')"
  echo "    time from request to reply:"
  tshark -r "$out" -Y "http.response" -T fields -e http.time -e http.response_for.uri 2>/dev/null \
    | awk '{ printf "      %7.3f s  %s\n", $1, $2 }'
  tcp_stats "$out"
}

info "Run 1/2: a good day, the search takes 0.08 s on the server (baseline)"
run "$CAP_DIR/scenario-04-baseline.pcapng" 0.08

info "Run 2/2: the search takes 4.2 s on the server (the problem)"
run "$CAP_DIR/scenario-04.pcapng" 4.2

info "Captures written:"
ls -lh "$CAP_DIR"/scenario-04*.pcapng
