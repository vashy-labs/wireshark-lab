#!/usr/bin/env bash
# =============================================================
#  Scenario 02 - "Everything is slow from the new branch"
#  Fault : high latency (300 ms round trip) on the path to the server,
#          met by an application that opens a new connection for every request
#  Output: captures/scenario-02.pcapng           (branch office: the problem)
#          captures/scenario-02-baseline.pcapng  (head office: same page, 2 ms round trip)
#          captures/scenario-02-fixed.pcapng     (branch office, connection reused)
#  Usage : cd ~/wireshark-lab && sudo ./scenarios/s02.sh
# =============================================================
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
require_root
trap cleanup EXIT

PC=s02-pc
RTR=s02-wan
SRV=s02-srv
SERVER_IP=10.20.2.20
SITE=portal.lab.local
RATE="rate 20mbit"
NEAR="1ms"       # one-way delay from head office  -> ~2 ms round trip
FAR="150ms"      # one-way delay from the branch   -> ~300 ms round trip

# The portal's start page: one HTML file and the 24 things it pulls in (path:size in bytes).
# Every object is small enough to arrive in a single round trip.
OBJECTS=(
  "portal/index.html:6200"
  "portal/css/main.css:9800"        "portal/css/theme.css:4100"
  "portal/js/app.js:11800"          "portal/js/menu.js:5300"
  "portal/js/widgets.js:8700"       "portal/js/charts.js:10900"
  "portal/img/logo.png:7400"        "portal/img/banner.png:11200"
  "portal/img/icon-mail.png:1800"   "portal/img/icon-docs.png:1900"
  "portal/img/icon-hr.png:1700"     "portal/img/icon-it.png:1800"
  "portal/img/icon-travel.png:2100" "portal/img/avatar.png:3600"
  "portal/api/session:420"          "portal/api/user:980"
  "portal/api/menu:2300"            "portal/api/notifications:1500"
  "portal/api/news:5200"            "portal/api/tasks:3100"
  "portal/api/calendar:4400"        "portal/api/weather:760"
  "portal/api/links:1900"           "portal/api/footer:640"
)

info "Building topology:  PC 10.20.1.10 --- WAN router --- portal server 10.20.2.20"
ns_add $PC
ns_add $RTR
ns_add $SRV
veth $PC  eth0 02:00:0a:14:01:0a   $RTR eth0 02:00:0a:14:01:01
veth $RTR eth1 02:00:0a:14:02:01   $SRV eth0 02:00:0a:14:02:14
addr $PC  eth0 10.20.1.10/24 ;  gw $PC 10.20.1.1
addr $RTR eth0 10.20.1.1/24  ;  addr $RTR eth1 10.20.2.1/24 ;  router $RTR
addr $SRV eth0 10.20.2.20/24 ;  gw $SRV 10.20.2.1

info "Starting the portal server with ${#OBJECTS[@]} objects"
web_server $SRV $SERVER_IP $SITE
URLS=()
for item in "${OBJECTS[@]}"; do
  path="${item%%:*}"
  size="${item##*:}"
  mkdir -p "$RUN_DIR/www/$(dirname "$path")"
  head -c "$size" /dev/urandom > "$RUN_DIR/www/$path"
  URLS+=("http://$SITE/$path")
done
chmod -R a+rX "$RUN_DIR/www"

# load_page <close|keepalive>
#   close     : a new TCP connection for every object (what the portal does today)
#   keepalive : one TCP connection, reused for every object (the fix)
load_page() {
  local mode=$1 url args=()
  if [[ $mode == close ]]; then
    for url in "${URLS[@]}"; do
      ip netns exec $PC curl -s --max-time 60 -o /dev/null \
        --resolve "$SITE:80:$SERVER_IP" -H "Connection: close" "$url" \
        || { echo "!! request failed: $url"; return 1; }
    done
  else
    for url in "${URLS[@]}"; do args+=(-o /dev/null "$url"); done
    ip netns exec $PC curl -s --max-time 120 --resolve "$SITE:80:$SERVER_IP" "${args[@]}" \
      || { echo "!! page load failed"; return 1; }
  fi
}

# run <capture-file> <one-way delay> <close|keepalive>
run() {
  local out=$1 delay=$2 mode=$3 t0 t1
  tc -n $RTR qdisc replace dev eth0 root netem delay $delay $RATE   # towards the PC
  tc -n $RTR qdisc replace dev eth1 root netem delay $delay $RATE   # towards the server
  # Forget what the previous run learned about this path, then resolve ARP before capturing
  ip netns exec $PC  ip tcp_metrics flush >/dev/null 2>&1 || true
  ip netns exec $SRV ip tcp_metrics flush >/dev/null 2>&1 || true
  ip netns exec $PC ping -c 1 -W 3 $SERVER_IP >/dev/null 2>&1 || true
  capture_start $PC eth0 "$out"
  t0=$(date +%s.%N)
  load_page "$mode"
  t1=$(date +%s.%N)
  capture_stop
  capture_check "$out"
  awk -v a="$t0" -v b="$t1" 'BEGIN { printf "    page load time         %.1f s\n", b - a }'
  printf "    %-22s %s\n" "tcp connections" \
    "$(tshark -r "$out" -Y "tcp.flags.syn==1 && tcp.flags.ack==0" 2>/dev/null | wc -l)"
  printf "    %-22s %s\n" "http requests" \
    "$(tshark -r "$out" -Y "http.request" 2>/dev/null | wc -l)"
  printf "    %-22s %s ms\n" "handshake round trip" \
    "$(tshark -r "$out" -Y "tcp.flags.syn==1 && tcp.flags.ack==1" -T fields -e tcp.analysis.ack_rtt 2>/dev/null \
        | head -1 | awk '{ printf "%.1f", $1 * 1000 }')"
  tcp_stats "$out"
}

info "Run 1/3: head office, 2 ms round trip (baseline)"
run "$CAP_DIR/scenario-02-baseline.pcapng" "$NEAR" close

info "Run 2/3: branch office, 300 ms round trip (the problem)"
run "$CAP_DIR/scenario-02.pcapng" "$FAR" close

info "Run 3/3: branch office, 300 ms round trip, connection reused (the fix)"
run "$CAP_DIR/scenario-02-fixed.pcapng" "$FAR" keepalive

info "Captures written:"
ls -lh "$CAP_DIR"/scenario-02*.pcapng
