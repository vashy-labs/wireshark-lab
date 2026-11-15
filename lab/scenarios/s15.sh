#!/usr/bin/env bash
# =============================================================
#  Scenario 15 - "Five seconds before anything happens"
#  Fault : the first DNS server in the PC's list has stopped answering. Every name
#          lookup waits 5 seconds for it, then asks the second server, which answers
#          at once. Every new page starts 5 seconds late, then loads quickly.
#  Output: captures/scenario-15.pcapng           PC side: three page loads, DNS1 silent
#          captures/scenario-15-dns1.pcapng      at DNS1 during the same three loads
#          captures/scenario-15-baseline.pcapng  PC side: three page loads, DNS1 healthy
#  Usage : cd ~/wireshark-lab && sudo ./scenarios/s15.sh
# =============================================================
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
require_root
trap cleanup EXIT
need dnsmasq dnsmasq-base

SW=s15-sw
PC=s15-pc
DNS1=s15-dns1     # first DNS server, 10.150.1.53
DNS2=s15-dns2     # second DNS server, 10.150.1.54
WEB=s15-web       # the intranet, 10.150.1.80
SITE=intranet.lab.local

info "Building topology:  PC, two DNS servers and the intranet server on one switch"
switch_add $SW
ns_add $PC
ns_add $DNS1
ns_add $DNS2
ns_add $WEB
no_ipv6 $PC $DNS1 $DNS2 $WEB
switch_port $SW $PC   eth0 02:00:0a:96:01:0a
switch_port $SW $DNS1 eth0 02:00:0a:96:01:35
switch_port $SW $DNS2 eth0 02:00:0a:96:01:36
switch_port $SW $WEB  eth0 02:00:0a:96:01:50
addr $PC   eth0 10.150.1.10/24
addr $DNS1 eth0 10.150.1.53/24
addr $DNS2 eth0 10.150.1.54/24
addr $WEB  eth0 10.150.1.80/24
# A little distance to the servers, so the times look like a real office network
tc -n $PC qdisc replace dev eth0 root netem delay 1ms

info "Starting the intranet and both DNS servers"
web_server $WEB 10.150.1.80 $SITE
head -c 4000 /dev/urandom > "$RUN_DIR/www/index.html"
chmod -R a+rX "$RUN_DIR/www"
dns_server $DNS1 10.150.1.53 dns1 --host-record=$SITE,10.150.1.80 --local-ttl=300
dns_server $DNS2 10.150.1.54 dns2 --host-record=$SITE,10.150.1.80 --local-ttl=300

# The PC's DNS settings, as DHCP would give them: DNS1 first, DNS2 second.
# No options: the resolver waits its standard 5 seconds for an answer.
resolver $PC "nameserver 10.150.1.53" "nameserver 10.150.1.54"

# fetch <n>  - open the intranet by name, as a browser would, and report how long the
# name lookup took and how long the whole page took
fetch() {
  local r rc=0
  r=$(ip netns exec $PC curl -s -o /dev/null --max-time 20 \
        -w '%{http_code} %{time_namelookup} %{time_total}' "http://$SITE/") || rc=$?
  awk -v n="$1" -v r="$r" -v rc="$rc" 'BEGIN { split(r, a, " ");
    printf "    page %-2s               HTTP %s, name lookup %.2f s, page complete %.2f s%s\n",
      n, a[1], a[2], a[3], (rc != 0 ? ", curl exit code " rc : "") }'
  sleep 1
}

info "Run 1/2: both DNS servers answer (baseline)"
capture_start $PC eth0 "$CAP_DIR/scenario-15-baseline.pcapng"
for i in 1 2 3; do fetch $i; done
capture_stop ; capture_check "$CAP_DIR/scenario-15-baseline.pcapng"

info "Run 2/2: DNS1 stops answering (the problem)"
# DNS1 still receives the questions but no longer answers them, like a server whose
# DNS service has hung. (Dropping them, rather than stopping the service, means the
# PC gets no "port unreachable" either - it just hears nothing.)
ip netns exec $DNS1 iptables -A INPUT -p udp --dport 53 -j DROP
capture2_start $DNS1 eth0 "$CAP_DIR/scenario-15-dns1.pcapng"
capture_start  $PC   eth0 "$CAP_DIR/scenario-15.pcapng"
for i in 1 2 3; do fetch $i; done
capture_stop ; capture2_stop
capture_check "$CAP_DIR/scenario-15.pcapng" ; capture_check "$CAP_DIR/scenario-15-dns1.pcapng"
printf "    %-22s %s\n" "DNS queries to DNS1" "$(count "$CAP_DIR/scenario-15.pcapng" "dns.flags.response == 0 && ip.dst == 10.150.1.53")"
printf "    %-22s %s\n" "answers from DNS1" "$(count "$CAP_DIR/scenario-15.pcapng" "dns.flags.response == 1 && ip.src == 10.150.1.53")"
printf "    %-22s %s\n" "answers from DNS2" "$(count "$CAP_DIR/scenario-15.pcapng" "dns.flags.response == 1 && ip.src == 10.150.1.54")"
printf "    %-22s %s\n" "queries seen at DNS1" "$(count "$CAP_DIR/scenario-15-dns1.pcapng" "dns.flags.response == 0")"
printf "    %-22s %s\n" "answers sent by DNS1" "$(count "$CAP_DIR/scenario-15-dns1.pcapng" "dns.flags.response == 1")"

info "Captures written:"
ls -lh "$CAP_DIR"/scenario-15*.pcapng
