#!/usr/bin/env bash
# =============================================================
#  Scenario 23 - "Copying a folder takes all afternoon"
#  Fault : none in the network. A branch office copies a project folder of 300 small
#          files from the head-office file server over a 40 ms WAN link. SMB asks and
#          waits for every file several times, so the copy is limited by round trips,
#          not by bandwidth.
#  Output: captures/scenario-23.pcapng       branch PC: the folder over the WAN (the ticket)
#          captures/scenario-23-lan.pcapng   the same folder copied inside head office
#          captures/scenario-23-zip.pcapng   the same files as one zip file over the WAN
#  Usage : cd ~/wireshark-lab && sudo ./scenarios/s23.sh
# =============================================================
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
require_root
trap cleanup EXIT
need smbd samba
need smbclient smbclient
need zip zip

PC=s23-pc         # branch PC, 10.230.1.10
WAN=s23-wan       # the WAN between branch and head office: 20 ms each way, 20 Mbit/s
FS=s23-fs         # head-office file server, 10.230.2.20

info "Building topology:  branch PC --- WAN (40 ms round trip, 20 Mbit/s) --- file server"
ns_add $PC
ns_add $WAN
ns_add $FS
no_ipv6 $PC $WAN $FS
veth $PC  eth0 02:00:0a:e6:01:0a   $WAN eth0 02:00:0a:e6:01:01
veth $WAN eth1 02:00:0a:e6:02:01   $FS  eth0 02:00:0a:e6:02:14
addr $PC  eth0 10.230.1.10/24 ;  gw $PC 10.230.1.1
addr $WAN eth0 10.230.1.1/24  ;  addr $WAN eth1 10.230.2.1/24 ;  router $WAN
addr $FS  eth0 10.230.2.20/24 ;  gw $FS 10.230.2.1

wan_on()  { tc -n $WAN qdisc replace dev eth0 root netem delay 20ms rate 20mbit
            tc -n $WAN qdisc replace dev eth1 root netem delay 20ms rate 20mbit; }
wan_off() { tc -n $WAN qdisc del dev eth0 root 2>/dev/null || true
            tc -n $WAN qdisc del dev eth1 root 2>/dev/null || true; }

info "Creating the share: a project folder with 300 small files, and the same as one zip"
SHARE="$RUN_DIR/share"
mkdir -p "$SHARE/Project-Alpha"
for i in $(seq -w 1 300); do
  head -c $(( 3000 + RANDOM % 9000 )) /dev/urandom > "$SHARE/Project-Alpha/drawing-$i.dwg"
done
( cd "$SHARE" && zip -qr Project-Alpha.zip Project-Alpha )
printf "    %-22s %s\n" "folder" "$(ls "$SHARE/Project-Alpha" | wc -l) files, $(du -sh "$SHARE/Project-Alpha" | cut -f1)"
printf "    %-22s %s\n" "zip file" "$(du -sh "$SHARE/Project-Alpha.zip" | cut -f1)"
smb_server $FS 10.230.2.20 "$SHARE"

# copy <what> <capture>  - the branch PC copies the folder or the zip file from \\10.230.2.20\files
copy() {
  local dest="$RUN_DIR/copy-$RANDOM" cmd t0 t1
  mkdir -p "$dest"
  if [[ $1 == folder ]]; then
    cmd="prompt OFF; recurse ON; lcd $dest; cd Project-Alpha; mget *"
  else
    cmd="lcd $dest; get Project-Alpha.zip"
  fi
  capture_start $PC eth0 "$2"
  t0=$(date +%s.%N)
  ip netns exec $PC smbclient //10.230.2.20/files -N -m SMB3 -c "$cmd" >/dev/null 2>"$RUN_DIR/smbclient.err" \
    || { echo "!! smbclient failed:"; head -3 "$RUN_DIR/smbclient.err"; }
  t1=$(date +%s.%N)
  sleep 1
  capture_stop ; capture_check "$2"
  awk -v a="$t0" -v b="$t1" -v w="$1" -v n="$(find "$dest" -type f | wc -l)" -v s="$(du -sk "$dest" | cut -f1)" \
    'BEGIN { printf "    copy %-17s %d files, %d KB in %.1f s (%.0f KB/s)\n", w, n, s, b-a, s/(b-a) }'
  printf "    %-22s %s\n" "SMB2 requests" "$(count "$2" "smb2.flags.response == 0")"
}

info "Run 1/3: the branch copies the folder over the WAN (the problem)"
wan_on
copy folder "$CAP_DIR/scenario-23.pcapng"

info "Run 2/3: the same folder copied inside head office (no WAN delay)"
wan_off
copy folder "$CAP_DIR/scenario-23-lan.pcapng"

info "Run 3/3: the same files as one zip file, over the WAN"
wan_on
copy zip "$CAP_DIR/scenario-23-zip.pcapng"

info "Captures written:"
ls -lh "$CAP_DIR"/scenario-23*.pcapng
