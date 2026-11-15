#!/usr/bin/env bash
# =============================================================
#  Scenario 27 - "Someone is trying every door"
#  What you see: in a capture from the server's switch, one machine on the LAN opens, or
#          tries to open, a connection to hundreds of ports on the server in a second or
#          two. This is a port scan: a tool checking which services are listening. It is
#          the usual first step before an attack, and it is easy to recognise once you
#          know the shape.
#  Output: captures/scenario-27.pcapng           the scan, seen at the server's switch
#          captures/scenario-27-baseline.pcapng  a normal minute on the same switch
#  Usage : cd ~/wireshark-lab && sudo ./scenarios/s27.sh
#  Note  : the "attacker" here is nmap run against our own lab server, so that you can see
#          what a scan looks like on the wire and practise spotting it. Only ever scan
#          machines you are responsible for.
# =============================================================
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
require_root
trap cleanup EXIT
need nmap nmap

SW=s27-sw
SRV=s27-srv       # the server, 10.70.1.10: a web server and an SSH port open
PC=s27-pc         # an ordinary office PC, 10.70.1.20
ATT=s27-att       # the machine the scan comes from, 10.70.1.66

info "Building topology:  server, office PC and one more machine on a switch (with a monitor port)"
switch_add $SW
ns_add $SRV
ns_add $PC
ns_add $ATT
no_ipv6 $SRV $PC $ATT
switch_port $SW $SRV eth0 02:00:0a:46:01:0a
switch_port $SW $PC  eth0 02:00:0a:46:01:14
switch_port $SW $ATT eth0 02:00:0a:46:01:42
addr $SRV eth0 10.70.1.10/24
addr $PC  eth0 10.70.1.20/24
addr $ATT eth0 10.70.1.66/24

info "Starting the server: a web server on port 80 and a listener on 22 (SSH)"
web_server $SRV 10.70.1.10 intranet.lab.local
head -c 1500 /dev/urandom | base64 > "$RUN_DIR/www/index.html"
chmod -R a+rX "$RUN_DIR/www"
# a plain listener on 22, so that one "interesting" open port shows up besides 80
ip netns exec $SRV sh -c 'while true; do echo "SSH-2.0-LabSSH"; sleep 1; done | nc -lk -p 22 >/dev/null 2>&1' &
sleep 1

switch_span $SW

info "Run 1/2: a normal minute - the office PC browses the intranet (baseline)"
capture_start $SW span0 "$CAP_DIR/scenario-27-baseline.pcapng"
for i in 1 2 3 4 5; do
  ip netns exec $PC curl -s -o /dev/null --resolve intranet.lab.local:80:10.70.1.10 "http://intranet.lab.local/?p=$i"
  sleep 0.3
done
capture_stop ; capture_check "$CAP_DIR/scenario-27-baseline.pcapng"

info "Run 2/2: the machine at 10.70.1.66 scans the server's first 1000 ports (the problem)"
capture_start $SW span0 "$CAP_DIR/scenario-27.pcapng"
# -sS a SYN scan (send SYN, never finish the handshake), -Pn skip the ping, -n no DNS,
# --max-retries 1 keep it quick, -p the first 1000 ports.
ip netns exec $ATT nmap -sS -Pn -n --max-retries 1 -p 1-1000 10.70.1.10 >"$RUN_DIR/nmap.out" 2>&1 || true
sleep 1
capture_stop ; capture_check "$CAP_DIR/scenario-27.pcapng"

printf "    %-24s %s\n" "SYNs from 10.70.1.66"   "$(count "$CAP_DIR/scenario-27.pcapng" "tcp.flags.syn == 1 && tcp.flags.ack == 0 && ip.src == 10.70.1.66")"
printf "    %-24s %s\n" "ports they tried"       "$(tshark -r "$CAP_DIR/scenario-27.pcapng" -Y "tcp.flags.syn == 1 && tcp.flags.ack == 0 && ip.src == 10.70.1.66" -T fields -e tcp.dstport 2>/dev/null | sort -un | wc -l)"
printf "    %-24s %s\n" "open (SYN,ACK back)"    "$(tshark -r "$CAP_DIR/scenario-27.pcapng" -Y "tcp.flags.syn == 1 && tcp.flags.ack == 1 && ip.src == 10.70.1.10" -T fields -e tcp.srcport 2>/dev/null | sort -un | paste -sd, -)"
printf "    %-24s %s\n" "closed (RST back)"      "$(count "$CAP_DIR/scenario-27.pcapng" "tcp.flags.reset == 1 && ip.src == 10.70.1.10")"

info "Captures written:"
ls -lh "$CAP_DIR"/scenario-27*.pcapng
