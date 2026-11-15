#!/usr/bin/env bash
# =============================================================
#  Scenario 24 - "The call connects, one side hears nothing"
#  Fault : one-way audio. A teleworker's desk phone sits behind a home router (NAT). It
#          announces its private address, 192.168.1.20, as the place to send its audio.
#          Its own audio reaches head office through the NAT; head office sends its
#          audio to 192.168.1.20, which nobody on the internet can reach.
#  Output: captures/scenario-24.pcapng           head-office phone: the call (the ticket)
#          captures/scenario-24-home.pcapng      teleworker's phone, same call
#          captures/scenario-24-baseline.pcapng  head-office phone: phone set to announce
#                                                its public address (the fix)
#          captures/scenario-24-baseline-home.pcapng  teleworker's phone, same call
#  Usage : cd ~/wireshark-lab && sudo ./scenarios/s24.sh
# =============================================================
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
require_root
trap cleanup EXIT
need sipp sip-tester

HQ=s24-hq         # head-office phone 1001, 10.240.1.10
CORE=s24-core     # head-office router, 10.240.1.1 / internet side 10.240.9.1
HOME_RTR=s24-home # teleworker's home router: internet 10.240.9.2, home network 192.168.1.1, NAT
TW=s24-tw         # teleworker's phone 2001, 192.168.1.20

info "Building topology:  HQ phone --- HQ router === internet === home router (NAT) --- teleworker phone"
ns_add $HQ
ns_add $CORE
ns_add $HOME_RTR
ns_add $TW
no_ipv6 $HQ $CORE $HOME_RTR $TW
veth $HQ       eth0 02:00:0a:f0:01:0a   $CORE     eth0 02:00:0a:f0:01:01
veth $CORE     eth1 02:00:0a:f0:09:01   $HOME_RTR eth0 02:00:0a:f0:09:02
veth $HOME_RTR eth1 02:00:c0:a8:01:01   $TW       eth0 02:00:c0:a8:01:14
addr $HQ       eth0 10.240.1.10/24 ;  gw $HQ 10.240.1.1
addr $CORE     eth0 10.240.1.1/24  ;  addr $CORE eth1 10.240.9.1/30 ;  router $CORE
addr $HOME_RTR eth0 10.240.9.2/30  ;  addr $HOME_RTR eth1 192.168.1.1/24 ;  router $HOME_RTR
gw   $HOME_RTR 10.240.9.1
addr $TW       eth0 192.168.1.20/24 ;  gw $TW 192.168.1.1
# The home router hides the home network behind its one internet address
ip netns exec $HOME_RTR iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
# A little distance between head office and the home office
tc -n $CORE qdisc replace dev eth1 root netem delay 10ms
tc -n $HOME_RTR qdisc replace dev eth0 root netem delay 10ms

# call <announce> <capture-hq> [capture-home]  - the teleworker calls head office
call() {
  local rc=0
  ip netns exec $HOME_RTR conntrack -F >/dev/null 2>&1 || true
  [[ -n ${3:-} ]] && capture2_start $TW eth0 "$3"
  capture_start $HQ eth0 "$2"
  phone_answer $HQ 10.240.1.10 10.240.1.10 hq
  phone_call $TW 192.168.1.20 "$1" 10.240.1.10 tw || rc=$?
  phone_wait hq
  sleep 1
  capture_stop ; capture_check "$2"
  [[ -n ${3:-} ]] && { capture2_stop ; capture_check "$3"; }
  printf "    %-22s %s\n" "call" "$([[ $rc == 0 ]] && echo "connected, talked, hung up normally" || echo "SIPp exit code $rc")"
  printf "    %-22s %s\n" "SDP from teleworker" \
    "$(tshark -r "$2" -Y "sdp && sip.Method == INVITE" -T fields -e sdp.connection_info.address 2>/dev/null | head -1)"
  echo "    RTP streams seen at the head-office phone:"
  rtp_report "$2"
}

info "Run 1/2: the phone announces its home address 192.168.1.20 (the problem)"
call 192.168.1.20 "$CAP_DIR/scenario-24.pcapng" "$CAP_DIR/scenario-24-home.pcapng"
echo "    RTP streams seen at the teleworker's phone:"
rtp_report "$CAP_DIR/scenario-24-home.pcapng"
printf "    %-22s %s\n" "ICMP unreachable" "$(count "$CAP_DIR/scenario-24.pcapng" "icmp.type == 3")"

info "Run 2/2: the fix - the phone announces the home router's internet address 10.240.9.2,"
info "         and the home router forwards the audio port (UDP 6000) to the phone"
ip netns exec $HOME_RTR iptables -t nat -A PREROUTING -i eth0 -p udp --dport 6000 -j DNAT --to-destination 192.168.1.20:6000
call 10.240.9.2 "$CAP_DIR/scenario-24-baseline.pcapng" "$CAP_DIR/scenario-24-baseline-home.pcapng"
echo "    RTP streams seen at the teleworker's phone:"
rtp_report "$CAP_DIR/scenario-24-baseline-home.pcapng"

info "Captures written:"
ls -lh "$CAP_DIR"/scenario-24*.pcapng
