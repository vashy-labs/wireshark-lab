#!/usr/bin/env bash
# =============================================================
#  Scenario 29 - "A thousand wrong passwords"
#  What you see: the admin page of the intranet server asks for a user name and password
#          (HTTP basic authentication). Next to the occasional normal login from a PC, one
#          machine sends a login attempt several times a second, each with a different
#          password, and gets "401 Unauthorized" every time. That is password guessing.
#  Output: captures/scenario-29.pcapng           at the server's switch, 40 seconds
#  Usage : cd ~/wireshark-lab && sudo ./scenarios/s29.sh
#  Note  : the guessing runs against the lab's own server with made-up passwords, so that
#          you can practise recognising it in a capture.
# =============================================================
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
require_root
trap cleanup EXIT

SW=s29-sw
SRV=s29-srv       # intranet server, 10.72.1.10, admin page at /admin/
PC=s29-pc         # Priya's PC, 10.72.1.20: she logs in now and then
GUESS=s29-guess   # the machine that guesses, 10.72.1.66
SITE=intranet.lab.local

info "Building topology:  server, Priya's PC and one more machine on a switch (with a monitor port)"
switch_add $SW
ns_add $SRV
ns_add $PC
ns_add $GUESS
no_ipv6 $SRV $PC $GUESS
switch_port $SW $SRV   eth0 02:00:0a:48:01:0a
switch_port $SW $PC    eth0 02:00:0a:48:01:14
switch_port $SW $GUESS eth0 02:00:0a:48:01:42
addr $SRV   eth0 10.72.1.10/24
addr $PC    eth0 10.72.1.20/24
addr $GUESS eth0 10.72.1.66/24
switch_span $SW

info "Starting the intranet server: /admin/ needs a user name and password"
mkdir -p "$RUN_DIR/www-web/admin"
printf "priya:%s\n" "$(openssl passwd -apr1 'Lab-Admin-2026')" > "$RUN_DIR/htpasswd"
chmod 644 "$RUN_DIR/htpasswd"
nginx_start $SRV web \
  "server {
     listen 10.72.1.10:80;
     server_name $SITE;
     root $RUN_DIR/www-web;
     location /admin/ { auth_basic \"Intranet admin\"; auth_basic_user_file $RUN_DIR/htpasswd; }
   }"
echo "<h1>Intranet</h1>" > "$RUN_DIR/www-web/index.html"
echo "<h1>Admin</h1>"    > "$RUN_DIR/www-web/admin/index.html"
chmod -R a+rX "$RUN_DIR/www-web"

login() {   # login <ns> <user> <password>  - prints the HTTP status
  ip netns exec "$1" curl --noproxy "*" -s -o /dev/null -w '%{http_code}' --max-time 3 \
    --resolve "$SITE:80:10.72.1.10" -u "$2:$3" "http://$SITE/admin/"
}

info "Capturing 40 seconds: Priya logs in now and then; after 8 seconds the guessing starts"
capture_start $SW span0 "$CAP_DIR/scenario-29.pcapng"
( for i in 1 2 3 4 5 6 7; do
    [[ $i == 4 ]] && login $PC priya 'Lab-Admin-2025' >/dev/null   # one typo, once
    login $PC priya 'Lab-Admin-2026' >/dev/null
    sleep 5
  done ) &
P=$!
sleep 8
n=0
for i in $(seq -w 1 150); do
  login $GUESS admin "guess-$i" >/dev/null
  n=$((n + 1))
  sleep 0.15
done
wait $P
capture_stop ; capture_check "$CAP_DIR/scenario-29.pcapng"

printf "    %-24s %s\n" "attempts by 10.72.1.66" "$n"
for src in 10.72.1.20 10.72.1.66; do
  printf "    %-24s %s\n" "responses to $src" \
    "$(tshark -r "$CAP_DIR/scenario-29.pcapng" -Y "http.response && ip.dst == $src" -T fields -e http.response.code 2>/dev/null | sort | uniq -c | awk '{printf "%s x %s  ", $1, $2}')"
done

info "Captures written:"
ls -lh "$CAP_DIR"/scenario-29*.pcapng
