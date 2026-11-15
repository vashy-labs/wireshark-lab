#!/usr/bin/env bash
# =============================================================
#  Scenario 19 - "Your connection is not private"
#  Fault : the web server's certificate expired four days ago. Browsers refuse the
#          connection during the TLS handshake. With TLS 1.3 the certificate and the
#          client's complaint are encrypted; with TLS 1.2 both can be read.
#  Output: captures/scenario-19.pcapng           TLS 1.3 (today's default): the handshake fails
#          captures/scenario-19-tls12.pcapng     the same, with TLS 1.2: certificate and alert readable
#          captures/scenario-19-baseline.pcapng  after the certificate is renewed
#  Usage : cd ~/wireshark-lab && sudo ./scenarios/s19.sh
# =============================================================
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
require_root
trap cleanup EXIT

PC=s19-pc
WEB=s19-web       # www.lab.local, 10.190.1.80
SITE=www.lab.local

info "Building topology:  PC --- web server"
ns_add $PC
ns_add $WEB
no_ipv6 $PC $WEB
veth $PC eth0 02:00:0a:be:01:0a   $WEB eth0 02:00:0a:be:01:50
addr $PC  eth0 10.190.1.10/24
addr $WEB eth0 10.190.1.80/24
tc -n $PC qdisc replace dev eth0 root netem delay 2ms

info "Creating the lab CA and two certificates for $SITE: one expired 4 days ago, one renewed"
pki_init
pki_cert old $SITE "-1 year -4 days" "-4 days"
pki_cert new $SITE "-1 day" "+1 year"
printf "    %-22s %s\n" "old certificate" "$(openssl x509 -in "$PKI/old.crt" -noout -enddate)"
printf "    %-22s %s\n" "new certificate" "$(openssl x509 -in "$PKI/new.crt" -noout -enddate)"

# site <cert-name>  - (re)start the web server with this certificate
site() {
  nginx_stop $WEB web
  nginx_start $WEB web \
    "server {
       listen 10.190.1.80:443 ssl;
       server_name $SITE;
       ssl_certificate     $PKI/$1.crt;
       ssl_certificate_key $PKI/$1.key;
       ssl_protocols TLSv1.2 TLSv1.3;
       root $RUN_DIR/www-web;
     }"
  head -c 2000 /dev/urandom | base64 > "$RUN_DIR/www-web/index.html"
  chmod -R a+rX "$RUN_DIR/www-web"
}

# browse [curl options]  - open https://www.lab.local/ trusting the lab CA, as a company PC does
browse() {
  local r rc=0 err
  r=$(ip netns exec $PC curl --noproxy "*" -s -S -o /dev/null --max-time 10 --cacert "$PKI/ca.crt" \
        --resolve "$SITE:443:10.190.1.80" -w '%{http_code}' "$@" "https://$SITE/" 2>"$RUN_DIR/curl.err") || rc=$?
  err=$(sed 's/^curl: ([0-9]*) //' "$RUN_DIR/curl.err" | head -1)
  printf "    %-22s HTTP %s%s\n" "browser $*" "$r" "${err:+, $err}"
  sleep 1
}

info "Run 1/3: the expired certificate, TLS 1.3 (the problem)"
site old
capture_start $PC eth0 "$CAP_DIR/scenario-19.pcapng"
browse
capture_stop ; capture_check "$CAP_DIR/scenario-19.pcapng"

info "Run 2/3: the expired certificate, TLS 1.2 (to see the certificate)"
capture_start $PC eth0 "$CAP_DIR/scenario-19-tls12.pcapng"
browse --tls-max 1.2
capture_stop ; capture_check "$CAP_DIR/scenario-19-tls12.pcapng"
printf "    %-22s %s\n" "TLS alert" \
  "$(tshark -r "$CAP_DIR/scenario-19-tls12.pcapng" -Y "tls.alert_message" -T fields -e tls.alert_message.desc 2>/dev/null | head -1 | sed 's/^/description code /')"

info "Run 3/3: the certificate is renewed (baseline)"
site new
capture_start $PC eth0 "$CAP_DIR/scenario-19-baseline.pcapng"
browse
capture_stop ; capture_check "$CAP_DIR/scenario-19-baseline.pcapng"

info "Captures written:"
ls -lh "$CAP_DIR"/scenario-19*.pcapng
