#!/usr/bin/env bash
# =============================================================
#  Scenario 18 - "Bad gateway"
#  Fault : the shop's web server (nginx) is a reverse proxy in front of an order
#          application. First the application is not running: the proxy answers
#          502 Bad Gateway. Then it runs but one call takes 8 seconds, longer than
#          the proxy waits: 504 Gateway Time-out.
#  Output: captures/scenario-18-baseline.pcapng      browser side: everything works
#          captures/scenario-18.pcapng               browser side: 502
#          captures/scenario-18-backend.pcapng       proxy to application, same moment
#          captures/scenario-18-slow.pcapng          browser side: 504
#          captures/scenario-18-slow-backend.pcapng  proxy to application, same moment
#  Usage : cd ~/wireshark-lab && sudo ./scenarios/s18.sh
# =============================================================
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
require_root
trap cleanup EXIT

PC=s18-pc
PROXY=s18-proxy   # shop.lab.local, 10.180.1.80; talks to the application from 10.180.2.1
APP=s18-app       # the order application, 10.180.2.20 port 8080
SITE=shop.lab.local

info "Building topology:  PC --- proxy (nginx) --- order application"
ns_add $PC
ns_add $PROXY
ns_add $APP
no_ipv6 $PC $PROXY $APP
veth $PC    eth0 02:00:0a:b4:01:0a   $PROXY eth0 02:00:0a:b4:01:50
veth $PROXY eth1 02:00:0a:b4:02:01   $APP   eth0 02:00:0a:b4:02:14
addr $PC    eth0 10.180.1.10/24
addr $PROXY eth0 10.180.1.80/24 ;  addr $PROXY eth1 10.180.2.1/24
addr $APP   eth0 10.180.2.20/24
tc -n $PC qdisc replace dev eth0 root netem delay 2ms

info "Starting the proxy: static pages itself, /api/ passed on to the application"
nginx_start $PROXY proxy \
  "server {
     listen 10.180.1.80:80;
     server_name $SITE;
     root $RUN_DIR/www-proxy;
     location /api/ {
       proxy_pass http://10.180.2.20:8080;
       proxy_connect_timeout 5s;
       proxy_read_timeout 5s;
     }
   }"
head -c 1500 /dev/urandom | base64 > "$RUN_DIR/www-proxy/index.html"
chmod -R a+rX "$RUN_DIR/www-proxy"

# shop <path>  - the browser asks for one URL
shop() {
  local r rc=0
  r=$(ip netns exec $PC curl --noproxy "*" -s -o /dev/null --max-time 15 --resolve "$SITE:80:10.180.1.80" \
        -w '%{http_code}|%{time_total}' "http://$SITE$1") || rc=$?
  awk -v p="$1" -v r="$r" -v rc="$rc" 'BEGIN { split(r, a, "|");
    printf "    GET %-22s HTTP %s after %.2f s%s\n", p, a[1], a[2], (rc != 0 ? ", curl exit code " rc : "") }'
  sleep 1
}

info "Run 1/3: the application is running (baseline)"
app_server $APP 10.180.2.20 8080 orders
capture_start $PC eth0 "$CAP_DIR/scenario-18-baseline.pcapng"
shop /
shop /api/orders
shop /api/report
capture_stop ; capture_check "$CAP_DIR/scenario-18-baseline.pcapng"

info "Run 2/3: the application is not running (502)"
app_stop orders
capture2_start $PROXY eth1 "$CAP_DIR/scenario-18-backend.pcapng"
capture_start  $PC    eth0 "$CAP_DIR/scenario-18.pcapng"
shop /
shop /api/orders
capture_stop ; capture2_stop
capture_check "$CAP_DIR/scenario-18.pcapng" ; capture_check "$CAP_DIR/scenario-18-backend.pcapng"
printf "    %-22s %s\n" "proxy error log" "$(grep -o 'connect() failed[^,]*' "$RUN_DIR/proxy-error.log" | tail -1)"

info "Run 3/3: the application runs, but the report takes 8 seconds (504)"
echo 8 > "$RUN_DIR/orders.delay"
app_server $APP 10.180.2.20 8080 orders
capture2_start $PROXY eth1 "$CAP_DIR/scenario-18-slow-backend.pcapng"
capture_start  $PC    eth0 "$CAP_DIR/scenario-18-slow.pcapng"
shop /api/orders
shop /api/report
sleep 3
capture_stop ; capture2_stop
capture_check "$CAP_DIR/scenario-18-slow.pcapng" ; capture_check "$CAP_DIR/scenario-18-slow-backend.pcapng"
printf "    %-22s %s\n" "proxy error log" "$(grep -o 'upstream timed out[^,]*' "$RUN_DIR/proxy-error.log" | tail -1)"

info "Captures written:"
ls -lh "$CAP_DIR"/scenario-18*.pcapng
