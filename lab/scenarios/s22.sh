#!/usr/bin/env bash
# =============================================================
#  Scenario 22 - "Reading what is encrypted"
#  Fault : the sales dashboard calls four API URLs over one HTTPS connection. One of
#          them, the report, takes 3.2 seconds. Encrypted, the capture shows only a
#          pause; with the client's TLS key log Wireshark shows which request it was.
#  Output: captures/scenario-22.pcapng            the dashboard loading, encrypted
#          captures/scenario-22.keys              the client's TLS key log (SSLKEYLOGFILE)
#          captures/scenario-22-with-keys.pcapng  the same capture with the keys inside it
#  Usage : cd ~/wireshark-lab && sudo ./scenarios/s22.sh
# =============================================================
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
require_root
trap cleanup EXIT

PC=s22-pc
API=s22-api       # api.lab.local, 10.220.1.80: nginx (HTTPS) in front of the application
SITE=api.lab.local

info "Building topology:  PC (dashboard) --- API server"
ns_add $PC
ns_add $API
no_ipv6 $PC $API
veth $PC eth0 02:00:0a:dc:01:0a   $API eth0 02:00:0a:dc:01:50
addr $PC  eth0 10.220.1.10/24
addr $API eth0 10.220.1.80/24
ip -n $API link set lo up
tc -n $PC qdisc replace dev eth0 root netem delay 5ms

info "Starting the API: nginx with TLS 1.3, the application behind it on the same server"
pki_init
pki_cert api $SITE "-30 days" "+1 year"
echo 3.2 > "$RUN_DIR/sales.delay"
app_server $API 127.0.0.1 8080 sales
nginx_start $API web \
  "server {
     listen 10.220.1.80:443 ssl;
     server_name $SITE;
     ssl_certificate     $PKI/api.crt;
     ssl_certificate_key $PKI/api.key;
     ssl_protocols TLSv1.3;
     location / { proxy_pass http://127.0.0.1:8080; proxy_http_version 1.1; proxy_set_header Connection \"\"; }
   }"

info "The dashboard loads: four API calls over one connection, keys written to a key log"
rm -f "$CAP_DIR/scenario-22.keys"
capture_start $PC eth0 "$CAP_DIR/scenario-22.pcapng"
ip netns exec $PC env SSLKEYLOGFILE="$CAP_DIR/scenario-22.keys" \
  curl --noproxy "*" -s --http1.1 --cacert "$PKI/ca.crt" --resolve "$SITE:443:10.220.1.80" \
  -o /dev/null -o /dev/null -o /dev/null -o /dev/null \
  -w '    GET %{url_effective}  HTTP %{http_code}, took %{time_total} s\n' \
  "https://$SITE/api/user" "https://$SITE/api/customers" "https://$SITE/api/report/monthly" "https://$SITE/api/alerts" \
  | sed "s#https://$SITE##"
sleep 1
capture_stop ; capture_check "$CAP_DIR/scenario-22.pcapng"
chown "$LAB_USER:$LAB_USER" "$CAP_DIR/scenario-22.keys"

info "Putting the keys into a copy of the capture (editcap --inject-secrets)"
editcap --inject-secrets "tls,$CAP_DIR/scenario-22.keys" \
  "$CAP_DIR/scenario-22.pcapng" "$CAP_DIR/scenario-22-with-keys.pcapng"
chown "$LAB_USER:$LAB_USER" "$CAP_DIR/scenario-22-with-keys.pcapng"
printf "    %-22s %s\n" "key log lines" "$(wc -l < "$CAP_DIR/scenario-22.keys")"
printf "    %-22s %s\n" "HTTP seen, encrypted" "$(count "$CAP_DIR/scenario-22.pcapng" "http")"
printf "    %-22s %s\n" "HTTP seen, with keys" "$(count "$CAP_DIR/scenario-22-with-keys.pcapng" "http")"
printf "    %-22s %s\n" "slowest response" \
  "$(tshark -r "$CAP_DIR/scenario-22-with-keys.pcapng" -Y "http.time" -T fields -e http.time -e http.response_for.uri 2>/dev/null | sort -rn | head -1 | awk '{printf "%.2f s for %s", $1, $2}')"

info "Captures written:"
ls -lh "$CAP_DIR"/scenario-22*
