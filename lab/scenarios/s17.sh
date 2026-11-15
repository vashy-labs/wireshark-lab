#!/usr/bin/env bash
# =============================================================
#  Scenario 17 - "Big answers get lost"
#  Fault : api.lab.local has 40 addresses (a pool of API servers). The answer is too
#          big for a plain 512-byte DNS reply, so the server sends it truncated and the
#          PC asks again over TCP port 53. A new firewall rule only allows DNS over UDP.
#          Small names keep working; the big one fails.
#  Output: captures/scenario-17.pcapng           PC side: www works, api fails (TCP 53 dropped)
#          captures/scenario-17-baseline.pcapng  PC side: before the rule, TCP 53 allowed
#          captures/scenario-17-edns.pcapng      PC side: dig, which uses EDNS, gets the answer
#  Usage : cd ~/wireshark-lab && sudo ./scenarios/s17.sh
# =============================================================
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
require_root
trap cleanup EXIT
need dnsmasq dnsmasq-base
need dig bind9-dnsutils

PC=s17-pc
FW=s17-fw         # router with the firewall
DNS=s17-dns       # 10.170.2.53
WEB=s17-web       # web and API servers, 10.170.3.x

info "Building topology:  PC --- firewall --- DNS server, web and API servers"
ns_add $PC
ns_add $FW
ns_add $DNS
ns_add $WEB
no_ipv6 $PC $FW $DNS $WEB
veth $PC eth0 02:00:0a:aa:01:0a   $FW  eth0 02:00:0a:aa:01:01
veth $FW eth1 02:00:0a:aa:02:01   $DNS eth0 02:00:0a:aa:02:35
veth $FW eth2 02:00:0a:aa:03:01   $WEB eth0 02:00:0a:aa:03:50
addr $PC  eth0 10.170.1.10/24 ;  gw $PC  10.170.1.1
addr $FW  eth0 10.170.1.1/24  ;  addr $FW eth1 10.170.2.1/24 ;  addr $FW eth2 10.170.3.254/24 ;  router $FW
addr $DNS eth0 10.170.2.53/24 ;  gw $DNS 10.170.2.1
addr $WEB eth0 10.170.3.80/24 ;  gw $WEB 10.170.3.254
tc -n $PC qdisc replace dev eth0 root netem delay 2ms

info "Starting the web server (www and all 40 API addresses) and the DNS server"
for i in $(seq 1 40); do ip -n $WEB addr add 10.170.3.$i/24 dev eth0; done
web_server $WEB 0.0.0.0 "www.lab.local api.lab.local"
head -c 3000 /dev/urandom > "$RUN_DIR/www/index.html"
chmod -R a+rX "$RUN_DIR/www"
: > "$RUN_DIR/hosts"
echo "10.170.3.80 www.lab.local" >> "$RUN_DIR/hosts"
for i in $(seq 1 40); do echo "10.170.3.$i api.lab.local" >> "$RUN_DIR/hosts"; done
dns_server $DNS 10.170.2.53 dns --addn-hosts="$RUN_DIR/hosts" --local-ttl=300

# The PC uses the standard resolver: no EDNS, so DNS answers over UDP are limited to 512 bytes
resolver $PC "nameserver 10.170.2.53"

# open <name>  - open http://<name>/ as a browser would
open_site() {
  local r rc=0
  r=$(ip netns exec $PC curl -s -o /dev/null --connect-timeout 10 \
        -w '%{http_code}|%{remote_ip}|%{time_namelookup}|%{time_total}' "http://$1/") || rc=$?
  awk -v n="$1" -v r="$r" -v rc="$rc" 'BEGIN { split(r, a, "|");
    printf "    %-22s HTTP %s, %s, name lookup %.2f s%s\n", n, a[1],
      (a[2] == "" ? "no address" : "connected to " a[2]), (rc == 28 ? 10 : a[3]),
      (rc == 28 ? ", curl exit code 28: name lookup timed out" : (rc != 0 ? ", curl exit code " rc : "")) }'
  sleep 1
}

info "Run 1/3: the firewall allows DNS over UDP and TCP (baseline)"
ip netns exec $FW iptables -A FORWARD -p udp --dport 53 -j ACCEPT
ip netns exec $FW iptables -A FORWARD -p tcp --dport 53 -j ACCEPT
capture_start $PC eth0 "$CAP_DIR/scenario-17-baseline.pcapng"
open_site www.lab.local
open_site api.lab.local
capture_stop ; capture_check "$CAP_DIR/scenario-17-baseline.pcapng"

info "Run 2/3: new firewall rule - DNS is UDP only, TCP port 53 is dropped (the problem)"
ip netns exec $FW iptables -R FORWARD 2 -p tcp --dport 53 -j DROP
capture_start $PC eth0 "$CAP_DIR/scenario-17.pcapng"
open_site www.lab.local
open_site api.lab.local
capture_stop ; capture_check "$CAP_DIR/scenario-17.pcapng"
printf "    %-22s %s\n" "truncated answers" "$(count "$CAP_DIR/scenario-17.pcapng" "dns.flags.truncated == 1")"
printf "    %-22s %s\n" "SYNs to port 53" "$(count "$CAP_DIR/scenario-17.pcapng" "tcp.dstport == 53 && tcp.flags.syn == 1")"
printf "    %-22s %s\n" "dropped by firewall" "$(ip netns exec $FW iptables -L FORWARD -v -n | awk '/DROP.*dpt:53/ {print $1 " packets"}')"

info "Run 3/3: the network team checks with dig, which uses EDNS"
capture_start $PC eth0 "$CAP_DIR/scenario-17-edns.pcapng"
printf "    %-22s %s\n" "dig api.lab.local" \
  "$(ip netns exec $PC dig +tries=1 +time=3 api.lab.local A | awk '/^;; ANSWER SECTION/ {a=1; next} a && /^$/ {a=0} a {n++} /MSG SIZE/ {s=$NF} END {print n " addresses, answer " s " bytes"}')"
capture_stop ; capture_check "$CAP_DIR/scenario-17-edns.pcapng"

info "Captures written:"
ls -lh "$CAP_DIR"/scenario-17*.pcapng
