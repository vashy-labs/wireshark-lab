#!/usr/bin/env bash
# =============================================================
#  Scenario 21 - "The wrong site answers"
#  Fault : portal.lab.local moved onto the shared web server, which also hosts
#          www.lab.local (its default site). The server picks the certificate by the
#          name the client puts in its ClientHello (SNI). An old invoice tool sends no
#          name, gets www.lab.local's certificate, and rejects it.
#  Output: captures/scenario-21.pcapng           old tool, no SNI: wrong certificate, refused
#          captures/scenario-21-baseline.pcapng  a browser, with SNI: the right certificate
#  Usage : cd ~/wireshark-lab && sudo ./scenarios/s21.sh
# =============================================================
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
require_root
trap cleanup EXIT

PC=s21-pc
WEB=s21-web       # shared web server, 10.210.1.80
SITE=portal.lab.local

info "Building topology:  PC --- shared web server (www.lab.local and portal.lab.local)"
ns_add $PC
ns_add $WEB
no_ipv6 $PC $WEB
veth $PC eth0 02:00:0a:d2:01:0a   $WEB eth0 02:00:0a:d2:01:50
addr $PC  eth0 10.210.1.10/24
addr $WEB eth0 10.210.1.80/24
tc -n $PC qdisc replace dev eth0 root netem delay 2ms

pki_init
pki_cert www    www.lab.local    "-30 days" "+1 year"
pki_cert portal portal.lab.local "-30 days" "+1 year"

# TLS 1.2, so that the certificate can be read in the capture (TLS 1.3 encrypts it)
nginx_start $WEB web \
  "server {
     listen 10.210.1.80:443 ssl default_server;
     server_name www.lab.local;
     ssl_certificate     $PKI/www.crt;
     ssl_certificate_key $PKI/www.key;
     ssl_protocols TLSv1.2;
     root $RUN_DIR/www-web;
   }" \
  "server {
     listen 10.210.1.80:443 ssl;
     server_name portal.lab.local;
     ssl_certificate     $PKI/portal.crt;
     ssl_certificate_key $PKI/portal.key;
     ssl_protocols TLSv1.2;
     root $RUN_DIR/www-web;
   }"
head -c 1200 /dev/urandom | base64 > "$RUN_DIR/www-web/index.html"
chmod -R a+rX "$RUN_DIR/www-web"

REQUEST="GET / HTTP/1.1\r\nHost: $SITE\r\nConnection: close\r\n\r\n"

info "Run 1/2: the old invoice tool - sends no server name (the problem)"
capture_start $PC eth0 "$CAP_DIR/scenario-21.pcapng"
out=$(printf "$REQUEST" | ip netns exec $PC timeout 10 openssl s_client -connect 10.210.1.80:443 \
        -noservername -CAfile "$PKI/ca.crt" -verify_hostname $SITE -verify_return_error -quiet 2>&1 || true)
sleep 1
capture_stop ; capture_check "$CAP_DIR/scenario-21.pcapng"
printf "    %-22s %s\n" "old tool" "$(echo "$out" | grep -m1 -oE 'verify error:[^:]*:[^:]*|HTTP/1.1 [0-9]+' || echo "$out" | head -1)"
printf "    %-22s %s\n" "certificate received" \
  "$(tshark -r "$CAP_DIR/scenario-21.pcapng" -Y "tls.handshake.certificate" -T fields -e x509ce.dNSName 2>/dev/null | head -1)"

info "Run 2/2: a browser - sends the server name (baseline)"
capture_start $PC eth0 "$CAP_DIR/scenario-21-baseline.pcapng"
r=$(ip netns exec $PC curl --noproxy "*" -s -o /dev/null --max-time 10 --cacert "$PKI/ca.crt" \
      --resolve "$SITE:443:10.210.1.80" -w '%{http_code}' "https://$SITE/" || true)
sleep 1
capture_stop ; capture_check "$CAP_DIR/scenario-21-baseline.pcapng"
printf "    %-22s HTTP %s\n" "browser" "$r"
printf "    %-22s %s\n" "certificate received" \
  "$(tshark -r "$CAP_DIR/scenario-21-baseline.pcapng" -Y "tls.handshake.certificate" -T fields -e x509ce.dNSName 2>/dev/null | head -1)"

info "Captures written:"
ls -lh "$CAP_DIR"/scenario-21*.pcapng
