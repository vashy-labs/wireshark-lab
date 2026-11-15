#!/usr/bin/env bash
# =============================================================
#  Scenario 08 - "It drops when nobody is typing"
#  Fault : a stateful firewall forgets idle connections after 20 seconds.
#          When the application speaks again, the firewall no longer knows the
#          connection and silently drops its packets.
#  Output: captures/scenario-08.pcapng           client side: 30 s idle, then the session is dead
#          captures/scenario-08-server.pcapng    the same moment, captured on the server
#          captures/scenario-08-fixed.pcapng     client side, TCP keep-alive every 10 s: session survives
#          captures/scenario-08-baseline.pcapng  client side, only 5 s idle: session works
#  Usage : cd ~/wireshark-lab && sudo ./scenarios/s08.sh
# =============================================================
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
require_root
trap cleanup EXIT

PC=s08-pc
FW=s08-fw
SRV=s08-srv
SERVER_IP=10.80.2.20
PORT=9200
FW_IDLE=20                     # the firewall forgets a silent connection after this many seconds
LINK="delay 5ms rate 100mbit"  # ~10 ms round trip

info "Building topology:  PC 10.80.1.10 --- firewall --- database server 10.80.2.20"
ns_add $PC
ns_add $FW
ns_add $SRV
veth $PC eth0 02:00:0a:50:01:0a   $FW  eth0 02:00:0a:50:01:01
veth $FW eth1 02:00:0a:50:02:01   $SRV eth0 02:00:0a:50:02:14
addr $PC  eth0 10.80.1.10/24 ;  gw $PC 10.80.1.1
addr $FW  eth0 10.80.1.1/24  ;  addr $FW eth1 10.80.2.1/24 ;  router $FW
addr $SRV eth0 10.80.2.20/24 ;  gw $SRV 10.80.2.1
tc -n $FW qdisc replace dev eth0 root netem $LINK
tc -n $FW qdisc replace dev eth1 root netem $LINK

info "Firewall rules: stateful, connections forgotten after ${FW_IDLE} s of silence"
fw() { ip netns exec $FW iptables "$@"; }
fw -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
fw -A FORWARD -p tcp --syn -m conntrack --ctstate NEW -j ACCEPT
fw -A FORWARD -p icmp -j ACCEPT
fw -A FORWARD -j DROP
ip netns exec $FW sysctl -qw net.netfilter.nf_conntrack_tcp_timeout_established=$FW_IDLE
ip netns exec $FW sysctl -qw net.netfilter.nf_conntrack_tcp_loose=0

# The database server: answers every query line with one result line.
cat > "$RUN_DIR/dbserver.py" <<'EOF'
import socket, sys, threading

def serve(conn):
    f = conn.makefile("rb")
    try:
        for line in f:
            conn.sendall(b"RESULT rows=42 for: " + line)
    except OSError:
        pass
    finally:
        conn.close()

s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((sys.argv[1], int(sys.argv[2])))
s.listen(8)
while True:
    c, _ = s.accept()
    threading.Thread(target=serve, args=(c,), daemon=True).start()
EOF

# The client: one query, a pause (the user reads the result), a second query.
#   args: server  port  idle-seconds  keepalive-seconds (0 = off)  seconds to wait for the 2nd reply
cat > "$RUN_DIR/dbclient.py" <<'EOF'
import socket, sys, time
host, port = sys.argv[1], int(sys.argv[2])
idle, keepalive, patience = float(sys.argv[3]), int(sys.argv[4]), float(sys.argv[5])
s = socket.create_connection((host, port))
if keepalive:
    s.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPIDLE, keepalive)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPINTVL, keepalive)
f = s.makefile("rb")
s.sendall(b"SELECT name, city FROM customers WHERE id = 1042\n")
first = "answered" if f.readline() else "no answer"
time.sleep(idle)
s.settimeout(patience)
start = time.time()
try:
    s.sendall(b"SELECT total FROM invoices WHERE customer = 1042\n")
    second = "answered after %.2f s" % (time.time() - start) if f.readline() else "connection closed"
except socket.timeout:
    second = "NO ANSWER after %.0f s" % patience
except OSError as e:
    second = "error: %s" % e
print("query 1 %s; query 2 %s" % (first, second))
s.close()
EOF

info "Starting the database server"
ip netns exec $SRV python3 "$RUN_DIR/dbserver.py" $SERVER_IP $PORT &
sleep 1.5

# run <capture-file> <idle seconds> <keepalive seconds> [server-side capture-file]
run() {
  local out=$1 r
  ip netns exec $PC ping -c 1 -W 2 $SERVER_IP >/dev/null 2>&1 || true
  [[ -n "${4:-}" ]] && capture2_start $SRV eth0 "$4"
  capture_start $PC eth0 "$out"
  r=$(ip netns exec $PC python3 "$RUN_DIR/dbclient.py" $SERVER_IP $PORT "$2" "$3" 12) || r="client failed"
  sleep 1
  capture_stop ; capture_check "$out"
  [[ -n "${4:-}" ]] && { capture2_stop ; capture_check "$4"; }
  printf "    %-22s %s\n" "client says" "$r"
  printf "    %-22s %s\n" "retransmissions" "$(count "$out" "tcp.analysis.retransmission")"
  printf "    %-22s %s\n" "keep-alives"     "$(count "$out" "tcp.analysis.keep_alive")"
  printf "    %-22s %s\n" "resets"          "$(count "$out" "tcp.flags.reset==1")"
  [[ -n "${4:-}" ]] && printf "    %-22s %s\n" "packets seen by server" "$(count "$4" "tcp")"
  return 0
}

info "Run 1/3: user pauses for 5 s (baseline)"
run "$CAP_DIR/scenario-08-baseline.pcapng" 5 0

info "Run 2/3: user pauses for 30 s, longer than the firewall remembers (the problem)"
run "$CAP_DIR/scenario-08.pcapng" 30 0 "$CAP_DIR/scenario-08-server.pcapng"

info "Run 3/3: 30 s pause again, with a TCP keep-alive every 10 s (the fix)"
run "$CAP_DIR/scenario-08-fixed.pcapng" 30 10

info "Captures written:"
ls -lh "$CAP_DIR"/scenario-08*.pcapng
