#!/usr/bin/env bash
# =============================================================
#  Scenario 20 - "The old client that cannot connect"
#  Fault : the upload server was hardened to accept TLS 1.3 only. An older upload
#          tool on the warehouse PCs can do no more than TLS 1.2. The server refuses
#          its first message with a "protocol version" alert.
#  Output: captures/scenario-20.pcapng           the old tool (TLS 1.2 at most): refused
#          captures/scenario-20-baseline.pcapng  a current client (TLS 1.3): works
#          captures/scenario-20-fixed.pcapng     the server accepts TLS 1.2 again: the old tool works
#  Usage : cd ~/wireshark-lab && sudo ./scenarios/s20.sh
# =============================================================
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
require_root
trap cleanup EXIT

PC=s20-pc
WEB=s20-upload    # upload.lab.local, 10.200.1.80
SITE=upload.lab.local

info "Building topology:  warehouse PC --- upload server"
ns_add $PC
ns_add $WEB
no_ipv6 $PC $WEB
veth $PC eth0 02:00:0a:c8:01:0a   $WEB eth0 02:00:0a:c8:01:50
addr $PC  eth0 10.200.1.10/24
addr $WEB eth0 10.200.1.80/24
tc -n $PC qdisc replace dev eth0 root netem delay 2ms

pki_init
pki_cert upload $SITE "-30 days" "+1 year"

# server <protocols>  - (re)start the upload server with these TLS versions
server() {
  nginx_stop $WEB web
  nginx_start $WEB web \
    "server {
       listen 10.200.1.80:443 ssl;
       server_name $SITE;
       ssl_certificate     $PKI/upload.crt;
       ssl_certificate_key $PKI/upload.key;
       ssl_protocols $1;
       root $RUN_DIR/www-web;
     }"
  head -c 1200 /dev/urandom | base64 > "$RUN_DIR/www-web/index.html"
  chmod -R a+rX "$RUN_DIR/www-web"
}

# connect <label> [curl options]  - one connection to https://upload.lab.local/
connect() {
  local label=$1 r rc=0 err
  shift
  r=$(ip netns exec $PC curl --noproxy "*" -s -S -o /dev/null --max-time 10 --cacert "$PKI/ca.crt" \
        --resolve "$SITE:443:10.200.1.80" -w '%{http_code}' "$@" "https://$SITE/" 2>"$RUN_DIR/curl.err") || rc=$?
  err=$(sed 's/^curl: ([0-9]*) //' "$RUN_DIR/curl.err" | head -1)
  printf "    %-22s HTTP %s%s\n" "$label" "$r" "${err:+, $err}"
  sleep 1
}

info "Run 1/3: server accepts TLS 1.3 only; the old tool can do TLS 1.2 at most (the problem)"
server "TLSv1.3"
capture_start $PC eth0 "$CAP_DIR/scenario-20.pcapng"
connect "old upload tool" --tlsv1.2 --tls-max 1.2
capture_stop ; capture_check "$CAP_DIR/scenario-20.pcapng"
printf "    %-22s %s\n" "TLS alert" \
  "$(tshark -r "$CAP_DIR/scenario-20.pcapng" -Y "tls.alert_message" -T fields -e ip.src -e tls.alert_message.desc 2>/dev/null | awk '{print "from " $1 ", description code " $2}' | head -1)"

info "Run 2/3: same server, a current client (baseline)"
capture_start $PC eth0 "$CAP_DIR/scenario-20-baseline.pcapng"
connect "current browser"
capture_stop ; capture_check "$CAP_DIR/scenario-20-baseline.pcapng"

info "Run 3/3: the server accepts TLS 1.2 and 1.3 again (the fix)"
server "TLSv1.2 TLSv1.3"
capture_start $PC eth0 "$CAP_DIR/scenario-20-fixed.pcapng"
connect "old upload tool" --tlsv1.2 --tls-max 1.2
capture_stop ; capture_check "$CAP_DIR/scenario-20-fixed.pcapng"

info "Captures written:"
ls -lh "$CAP_DIR"/scenario-20*.pcapng
