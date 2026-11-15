#!/usr/bin/env bash
# =============================================================
#  Scenario 25 - "Robot voices"
#  Fault : the branch office runs on its backup 4G link since the fibre was cut. The
#          link delays packets unevenly (jitter) and loses some. Calls from the branch
#          sound choppy and robotic at head office; the branch hears head office fine,
#          because the problem is in one direction only.
#  Output: captures/scenario-25.pcapng           head-office phone: a call over the 4G link
#          captures/scenario-25-baseline.pcapng  head-office phone: the same call over fibre
#  Usage : cd ~/wireshark-lab && sudo ./scenarios/s25.sh
# =============================================================
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
require_root
trap cleanup EXIT
need sipp sip-tester

HQ=s25-hq         # head-office phone 1001, 10.250.1.10
WAN=s25-wan       # the link between the offices
BR=s25-branch     # branch phone 2001, 10.250.2.20

info "Building topology:  HQ phone --- WAN link --- branch phone"
ns_add $HQ
ns_add $WAN
ns_add $BR
no_ipv6 $HQ $WAN $BR
veth $HQ  eth0 02:00:0a:fa:01:0a   $WAN eth0 02:00:0a:fa:01:01
veth $WAN eth1 02:00:0a:fa:02:01   $BR  eth0 02:00:0a:fa:02:14
addr $HQ  eth0 10.250.1.10/24 ;  gw $HQ 10.250.1.1
addr $WAN eth0 10.250.1.1/24  ;  addr $WAN eth1 10.250.2.1/24 ;  router $WAN
addr $BR  eth0 10.250.2.20/24 ;  gw $BR 10.250.2.1

# link <fibre|4g>  - eth0 of the WAN router sends towards head office, eth1 towards the branch
link() {
  if [[ $1 == fibre ]]; then
    tc -n $WAN qdisc replace dev eth0 root netem delay 8ms
    tc -n $WAN qdisc replace dev eth1 root netem delay 8ms
  else
    # towards head office: 40 ms on average, give or take 15 ms
    tc -n $WAN qdisc replace dev eth0 root netem delay 40ms 15ms distribution normal
    # ... and 3% of the voice packets lost (only voice, so that the call itself still connects)
    ip netns exec $WAN iptables -A FORWARD -o eth0 -p udp --dport 6000 \
      -m statistic --mode random --probability 0.03 -j DROP
    # towards the branch: slower than fibre, but steady
    tc -n $WAN qdisc replace dev eth1 root netem delay 30ms 2ms
  fi
}

# call <capture>  - the branch phone calls head office and talks for about 8 seconds
call() {
  local rc=0
  capture_start $HQ eth0 "$1"
  phone_answer $HQ 10.250.1.10 10.250.1.10 hq
  phone_call $BR 10.250.2.20 10.250.2.20 10.250.1.10 br || rc=$?
  phone_wait hq
  sleep 1
  capture_stop ; capture_check "$1"
  printf "    %-22s %s\n" "call" "$([[ $rc == 0 ]] && echo "connected, talked, hung up normally" || echo "SIPp exit code $rc")"
  echo "    RTP streams seen at the head-office phone:"
  rtp_report "$1"
}

info "Run 1/2: the branch on its fibre link (baseline)"
link fibre
call "$CAP_DIR/scenario-25-baseline.pcapng"

info "Run 2/2: the branch on its backup 4G link (the problem)"
link 4g
call "$CAP_DIR/scenario-25.pcapng"

info "Captures written:"
ls -lh "$CAP_DIR"/scenario-25*.pcapng
