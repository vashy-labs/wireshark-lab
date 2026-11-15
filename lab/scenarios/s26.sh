#!/usr/bin/env bash
# =============================================================
#  Scenario 26 - "Slow every day at two o'clock"
#  Fault : the branch's file server starts its backup to head office at two o'clock.
#          The backup sends as fast as the 8 Mbit/s WAN link allows, the link's queue
#          fills up, and everybody else's traffic waits in that queue.
#  Output: captures/scenario-26.pcapng   the branch router's LAN side (where branch traffic
#                                        enters the WAN queue): normal - backup - normal again
#  Usage : cd ~/wireshark-lab && sudo ./scenarios/s26.sh
# =============================================================
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
require_root
trap cleanup EXIT
need iperf3 iperf3

SW=s26-sw
PC1=s26-pc1       # Asha, works in the ERP system all day      172.26.1.10
PC2=s26-pc2       # Ravi, opens documents on the intranet     172.26.1.11
FS=s26-fs         # branch file server, runs the backup        172.26.1.30
BR=s26-br         # branch router, WAN link 8 Mbit/s           172.26.1.1 / 172.26.9.1
HQ=s26-hq         # head-office router                         172.26.9.2 / 172.26.2.1
APP=s26-app       # ERP and intranet server                    172.26.2.80
BAK=s26-bak       # backup server                              172.26.3.90

info "Building topology:  branch LAN (2 PCs, file server) --- branch router === 8 Mbit/s WAN === head office"
switch_add $SW
for n in $PC1 $PC2 $FS $BR $HQ $APP $BAK; do ns_add $n; done
no_ipv6 $PC1 $PC2 $FS $BR $HQ $APP $BAK
switch_port $SW $PC1 eth0 02:00:ac:1a:01:0a
switch_port $SW $PC2 eth0 02:00:ac:1a:01:0b
switch_port $SW $FS  eth0 02:00:ac:1a:01:1e
switch_port $SW $BR  eth0 02:00:ac:1a:01:01
veth $BR  eth1 02:00:ac:1a:09:01   $HQ  eth0 02:00:ac:1a:09:02
veth $HQ  eth1 02:00:ac:1a:02:01   $APP eth0 02:00:ac:1a:02:50
veth $HQ  eth2 02:00:ac:1a:03:01   $BAK eth0 02:00:ac:1a:03:5a
addr $PC1 eth0 172.26.1.10/24 ;  gw $PC1 172.26.1.1
addr $PC2 eth0 172.26.1.11/24 ;  gw $PC2 172.26.1.1
addr $FS  eth0 172.26.1.30/24 ;  gw $FS  172.26.1.1
addr $BR  eth0 172.26.1.1/24  ;  addr $BR eth1 172.26.9.1/30 ;  router $BR ;  gw $BR 172.26.9.2
addr $HQ  eth0 172.26.9.2/30  ;  addr $HQ eth1 172.26.2.1/24 ;  addr $HQ eth2 172.26.3.1/24
router $HQ ;  gw $HQ 172.26.9.1
addr $APP eth0 172.26.2.80/24 ;  gw $APP 172.26.2.1
addr $BAK eth0 172.26.3.90/24 ;  gw $BAK 172.26.3.1

# The WAN link: 8 Mbit/s from the branch to head office, with a large buffer in the router
# (up to 500 ms of queue, typical of a small office router), and 10 ms each way.
tc -n $BR qdisc replace dev eth1 root handle 1: tbf rate 8mbit burst 32kbit latency 500ms
tc -n $BR qdisc add dev eth1 parent 1:1 handle 10: netem delay 10ms
tc -n $HQ qdisc replace dev eth0 root netem delay 10ms

info "Starting the ERP / intranet server and the backup server"
web_server $APP 172.26.2.80 erp.lab.local
head -c 2000 /dev/urandom | base64 > "$RUN_DIR/www/index.html"
head -c 300000 /dev/urandom > "$RUN_DIR/www/manual.pdf"
chmod -R a+rX "$RUN_DIR/www"
ip netns exec $BAK iperf3 -s -1 -B 172.26.3.90 >/dev/null 2>&1 &

# Asha: an ERP screen every 0.5 s (a small request and answer) for 30 seconds
asha() {
  for i in $(seq 1 60); do
    ip netns exec $PC1 curl --noproxy "*" -s -o /dev/null --max-time 5 -w '%{time_total}\n' \
      --resolve erp.lab.local:80:172.26.2.80 "http://erp.lab.local/?screen=$i" || echo 5
    sleep 0.5
  done > "$RUN_DIR/asha.times"
}
# Ravi: opens a 300 KB document every 4 seconds
ravi() {
  for i in $(seq 1 8); do
    ip netns exec $PC2 curl --noproxy "*" -s -o /dev/null --max-time 10 \
      --resolve erp.lab.local:80:172.26.2.80 "http://erp.lab.local/manual.pdf" || true
    sleep 4
  done
}

info "Capturing on the branch router's LAN side; the backup starts after 8 seconds"
capture_start $BR eth0 "$CAP_DIR/scenario-26.pcapng"
asha & A=$!
ravi & R=$!
sleep 8
echo "    $(date +%T)  the backup starts"
ip netns exec $FS iperf3 -c 172.26.3.90 -B 172.26.1.30 -t 12 >"$RUN_DIR/iperf.out" 2>&1 || true
echo "    $(date +%T)  the backup has finished"
wait $A $R 2>/dev/null || true
sleep 1
capture_stop ; capture_check "$CAP_DIR/scenario-26.pcapng"

awk 'NR <= 15            { b += $1; nb++ }
     NR >= 18 && NR <= 38 { d += $1; nd++; if ($1 > m) m = $1 }
     NR >= 50            { a += $1; na++ }
     END { printf "    %-22s before %.0f ms, during the backup %.0f ms (worst %.0f ms), after %.0f ms\n",
           "ERP screen, average", 1000*b/nb, 1000*d/nd, 1000*m, 1000*a/na }' "$RUN_DIR/asha.times"
printf "    %-22s %s\n" "backup throughput" "$(grep -E 'sender$' "$RUN_DIR/iperf.out" | awk '{print $7, $8}')"
printf "    %-22s %s\n" "capture" "$(capinfos -c -M "$CAP_DIR/scenario-26.pcapng" | awk -F': *' '/Number of packets/ {print $2 " packets"}')"
printf "    %-22s %s\n" "ERP in the capture" \
  "$(tshark -r "$CAP_DIR/scenario-26.pcapng" -Y "http.response && ip.dst == 172.26.1.10" -T fields -e http.time 2>/dev/null \
     | sort -n | awk '{v[NR]=$1} END {printf "%d responses, fastest %.0f ms, slowest %.0f ms", NR, 1000*v[1], 1000*v[NR]}')"

info "Captures written:"
ls -lh "$CAP_DIR"/scenario-26*.pcapng
