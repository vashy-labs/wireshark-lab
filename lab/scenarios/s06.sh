#!/usr/bin/env bash
# =============================================================
#  Scenario 06 - "Forty milliseconds, every time"
#  Fault : Nagle's algorithm meets delayed ACK. The client program sends each
#          transaction in two small writes. Its TCP holds the second write back
#          until the first is acknowledged; the server's TCP delays that
#          acknowledgment by about 40 ms. Every transaction loses 40 ms.
#  Output: captures/scenario-06.pcapng           two writes per transaction (the problem)
#          captures/scenario-06-fixed.pcapng     same program with TCP_NODELAY set
#          captures/scenario-06-baseline.pcapng  same program, one write per transaction
#  Usage : cd ~/wireshark-lab && sudo ./scenarios/s06.sh
# =============================================================
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
require_root
trap cleanup EXIT

PC=s06-pc
RTR=s06-sw
SRV=s06-srv
SERVER_IP=10.60.2.20
PORT=9100
TXNS=100
LAN="delay 500us rate 1gbit"   # same data centre: ~1 ms round trip

info "Building topology:  order client 10.60.1.10 --- switch --- ledger server 10.60.2.20"
ns_add $PC
ns_add $RTR
ns_add $SRV
veth $PC  eth0 02:00:0a:3c:01:0a   $RTR eth0 02:00:0a:3c:01:01
veth $RTR eth1 02:00:0a:3c:02:01   $SRV eth0 02:00:0a:3c:02:14
addr $PC  eth0 10.60.1.10/24 ;  gw $PC 10.60.1.1
addr $RTR eth0 10.60.1.1/24  ;  addr $RTR eth1 10.60.2.1/24 ;  router $RTR
addr $SRV eth0 10.60.2.20/24 ;  gw $SRV 10.60.2.1
tc -n $RTR qdisc replace dev eth0 root netem $LAN
tc -n $RTR qdisc replace dev eth1 root netem $LAN

# The ledger server: reads one transaction (a header line, then a body of the
# announced length) and answers at once with a one-line result.
cat > "$RUN_DIR/ledger.py" <<'EOF'
import socket, sys, threading

def serve(conn):
    f = conn.makefile("rb")
    try:
        while True:
            header = f.readline()
            if not header:
                break
            parts = header.split()            # b"TXN", id, b"LEN", length
            body = f.read(int(parts[3]))
            if len(body) < int(parts[3]):
                break
            conn.sendall(b"OK " + parts[1] + b" posted amount=" + body[7:15] + b"\n")
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

# The order client: posts N transactions on one connection, one after another.
#   mode "two"     : header and body in two writes (how the program was written)
#   mode "nodelay" : the same two writes, with TCP_NODELAY set on the socket
#   mode "one"     : header and body joined and sent in one write
cat > "$RUN_DIR/orders.py" <<'EOF'
import socket, sys, time
host, port, count, mode = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
s = socket.create_connection((host, port))
if mode == "nodelay":
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
f = s.makefile("rb")
start = time.time()
for i in range(1, count + 1):
    body = ("amount=%08d account=ACC-%05d ref=ORDER-%06d note=%s\n"
            % (1000 + i, 40000 + i, 700000 + i, "x" * 96)).encode()
    header = ("TXN %06d LEN %d\n" % (i, len(body))).encode()
    if mode == "one":
        s.sendall(header + body)
    else:
        s.sendall(header)
        s.sendall(body)
    if not f.readline():
        sys.exit("server closed the connection")
print("%.2f" % (time.time() - start))
s.close()
EOF

info "Starting the ledger server"
ip netns exec $SRV python3 "$RUN_DIR/ledger.py" $SERVER_IP $PORT &
sleep 1.5

# run <capture-file> <mode>
run() {
  local out=$1 t
  ip netns exec $PC  ip tcp_metrics flush >/dev/null 2>&1 || true
  ip netns exec $SRV ip tcp_metrics flush >/dev/null 2>&1 || true
  ip netns exec $PC ping -c 1 -W 2 $SERVER_IP >/dev/null 2>&1 || true
  capture_start $PC eth0 "$out"
  t=$(ip netns exec $PC python3 "$RUN_DIR/orders.py" $SERVER_IP $PORT $TXNS "$2") \
    || { echo "!! client failed"; return 1; }
  capture_stop ; capture_check "$out"
  printf "    %-22s %s s for %s transactions\n" "total time" "$t" "$TXNS"
  printf "    %-22s %s\n" "packets"               "$(count "$out" "tcp")"
  printf "    %-22s %s\n" "gaps of 35 ms or more" "$(count "$out" "tcp.time_delta > 0.035")"
  tcp_stats "$out"
}

info "Run 1/3: one write per transaction (baseline)"
run "$CAP_DIR/scenario-06-baseline.pcapng" one

info "Run 2/3: two writes per transaction (the problem)"
run "$CAP_DIR/scenario-06.pcapng" two

info "Run 3/3: two writes per transaction, TCP_NODELAY set (the fix)"
run "$CAP_DIR/scenario-06-fixed.pcapng" nodelay

info "Captures written:"
ls -lh "$CAP_DIR"/scenario-06*.pcapng
