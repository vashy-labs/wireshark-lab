#!/usr/bin/env bash
# =============================================================
#  Wireshark Troubleshooting Lab Scenarios - shared helpers
#  Location: ~/wireshark-lab/lib/common.sh
#  Sourced by every scenario script. Do not run it directly.
# =============================================================
set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CAP_DIR="$LAB_DIR/captures"
LAB_USER="${SUDO_USER:-lab}"
NS_LIST=()
CAP_PID=""
RUN_DIR=""
_VETH_N=0

info() { echo "==> $*"; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo:  sudo $0"
    exit 1
  fi
  mkdir -p "$CAP_DIR"
  RUN_DIR="$(mktemp -d /tmp/wslab-XXXXXX)"
  chmod 755 "$RUN_DIR"
}

# ns_add <namespace>  - create an isolated "machine"
ns_add() {
  ip netns del "$1" 2>/dev/null || true
  ip netns add "$1"
  ip -n "$1" link set lo up
  NS_LIST+=("$1")
}

# Turn off segmentation/checksum offloads so captures show
# real wire-size packets with correct checksums.
_no_offload() {
  local f
  for f in tso gso gro tx rx; do
    ip netns exec "$1" ethtool -K "$2" "$f" off >/dev/null 2>&1 || true
  done
}

# _set_mac <ns> <if> <mac>  - set a MAC address and make sure it stays set
_set_mac() {
  local i
  for i in 1 2 3 4 5; do
    ip -n "$1" link set "$2" address "$3"
    sleep 0.1
    [ "$(ip -n "$1" -br link show dev "$2" | awk '{print $3}')" = "$3" ] && return 0
  done
  echo "!! $1 $2: MAC address $3 did not stick"; return 1
}

# veth <nsA> <ifA> <macA> <nsB> <ifB> <macB>  - a virtual cable between two machines
veth() {
  local na=$1 ia=$2 ma=$3 nb=$4 ib=$5 mb=$6
  _VETH_N=$((_VETH_N + 1))
  local ta="wsa$$_$_VETH_N" tb="wsb$$_$_VETH_N"
  ip link add "$ta" type veth peer name "$tb"
  ip link set "$ta" netns "$na"
  ip link set "$tb" netns "$nb"
  ip -n "$na" link set "$ta" name "$ia"
  ip -n "$nb" link set "$tb" name "$ib"
  # Ubuntu's udev gives every new veth its own MAC address a moment after it is
  # created, and could overwrite ours. Wait for it, then set the address inside the
  # namespace (udev no longer touches the interface there) and check it stuck.
  udevadm settle -t 5 2>/dev/null || true
  _set_mac "$na" "$ia" "$ma"
  _set_mac "$nb" "$ib" "$mb"
  _no_offload "$na" "$ia"
  _no_offload "$nb" "$ib"
  ip -n "$na" link set "$ia" up
  ip -n "$nb" link set "$ib" up
}

# addr <ns> <if> <ip/cidr>
addr() { ip -n "$1" addr add "$3" dev "$2"; }

# gw <ns> <gateway-ip>
gw() { ip -n "$1" route add default via "$2"; }

# router <ns>  - enable IPv4 forwarding inside the namespace
router() { ip netns exec "$1" sysctl -qw net.ipv4.ip_forward=1; }

# no_ipv6 <ns> ...  - switch IPv6 off in these namespaces (keeps ARP and DHCP captures free of IPv6 noise)
no_ipv6() {
  local ns
  for ns in "$@"; do
    ip netns exec "$ns" sysctl -qw net.ipv6.conf.all.disable_ipv6=1 2>/dev/null || true
    ip netns exec "$ns" sysctl -qw net.ipv6.conf.default.disable_ipv6=1 2>/dev/null || true
  done
}

# switch_add <ns>  - a layer-2 switch: a namespace holding one bridge, br0
switch_add() {
  ns_add "$1"
  no_ipv6 "$1"
  ip -n "$1" link add br0 type bridge
  ip -n "$1" link set br0 up
}

# switch_port <switch-ns> <host-ns> <host-if> <host-mac>  - plug a host into the switch
switch_port() {
  local sw=$1 ns=$2 ifc=$3 mac=$4 port
  port="port$((_VETH_N + 1))"
  veth "$ns" "$ifc" "$mac" "$sw" "$port" "02:ff:00:00:00:$(printf %02x $((_VETH_N + 1)))"
  ip -n "$sw" link set "$port" master br0
}

# switch_span <switch-ns>  - a mirror (SPAN) port: every frame that enters any port of the
# switch is also copied to the interface "span0" in the switch, where it can be captured.
# Call it after all switch_port calls. Capture with: capture_start <switch-ns> span0 <file>
switch_span() {
  local sw=$1 p
  ip -n "$sw" link add span0 type veth peer name span1
  ip -n "$sw" link set span0 up
  ip -n "$sw" link set span1 up
  for p in $(ip -n "$sw" -o link show master br0 | awk -F': ' '{print $2}' | cut -d@ -f1); do
    tc -n "$sw" qdisc add dev "$p" handle ffff: ingress
    tc -n "$sw" filter add dev "$p" parent ffff: protocol all u32 match u32 0 0 \
      action mirred egress mirror dev span0
  done
}

# need <command> <package>  - install a package if its command is missing
need() {
  command -v "$1" >/dev/null 2>&1 && return 0
  info "Installing $2 (needed for this scenario)"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$2" >/dev/null \
    || { echo "!! could not install $2 - is the VM online?"; exit 1; }
}

# dhcp_server <ns> <if> <log-name> <dnsmasq options...>  - a DHCP server (dnsmasq, DHCP only)
dhcp_server() {
  local ns=$1 ifc=$2 name=$3
  shift 3
  rm -f "$RUN_DIR/$name.log"
  ip netns exec "$ns" dnsmasq --conf-file=/dev/null --keep-in-foreground --no-resolv --no-hosts \
    --port=0 --interface="$ifc" --bind-interfaces --user=root --group=root \
    --log-dhcp --log-facility="$RUN_DIR/$name.log" --pid-file="$RUN_DIR/$name.pid" "$@" &
  sleep 1
}

# dhcp_client <ns> <if> <seconds>  - run a real DHCP client (dhcpcd) for this many seconds.
# If no server answers it falls back to a 169.254.x.x address and keeps asking.
# Prints the address and gateway it ends up with.
dhcp_client() {
  local ns=$1 ifc=$2 secs=$3
  rm -f /var/lib/dhcpcd/*.lease /var/lib/dhcpcd/*"$ifc"* 2>/dev/null || true
  printf '%s\n' clientid persistent noipv6rs ipv4only \
    'option subnet_mask, routers, domain_name_servers' > "$RUN_DIR/dhcpcd.conf"
  ip netns exec "$ns" timeout "$secs" dhcpcd -f "$RUN_DIR/dhcpcd.conf" -c /bin/true -4 -B -t 0 \
    "$ifc" >"$RUN_DIR/dhcpcd.log" 2>&1 || true
  printf "    %-22s %s\n" "address" \
    "$(ip -n "$ns" -4 -o addr show dev "$ifc" | awk '{print $4}' | paste -sd, - | sed 's/^$/none/')"
  printf "    %-22s %s\n" "default gateway" \
    "$(ip -n "$ns" route show default | awk '$2 == "via" {print $3; next} {print "none (" $0 ")"}' | paste -sd, - | sed 's/^$/none/')"
}

# dns_server <ns> <listen-ip> <log-name> <dnsmasq options...>  - a DNS server (dnsmasq, DNS only,
# answers from its own records and never forwards). It is the authority for lab.local, so
# a question it has no record for gets a proper "no such data" answer, not "refused". Logs every query to $RUN_DIR/<log-name>.log.
dns_server() {
  local ns=$1 ip=$2 name=$3
  shift 3
  rm -f "$RUN_DIR/$name.log"
  ip netns exec "$ns" dnsmasq --conf-file=/dev/null --keep-in-foreground --no-resolv --no-hosts \
    --local=/lab.local/ --listen-address="$ip" --bind-interfaces --user=root --group=root \
    --log-queries --log-facility="$RUN_DIR/$name.log" --pid-file="$RUN_DIR/$name.pid" "$@" &
  sleep 1
}

# resolver <ns> <line>...  - the machine's /etc/resolv.conf (its DNS servers and options).
# "ip netns exec" shows /etc/netns/<ns>/resolv.conf to programs as /etc/resolv.conf.
resolver() {
  local ns=$1
  shift
  mkdir -p "/etc/netns/$ns"
  printf '%s\n' "$@" > "/etc/netns/$ns/resolv.conf"
  # names are looked up in /etc/hosts, then straight from these DNS servers (no local cache)
  sed 's/^hosts:.*/hosts: files dns/' /etc/nsswitch.conf > "/etc/netns/$ns/nsswitch.conf"
}

# web_server <ns> <listen-ip> <server-name>  - nginx serving $RUN_DIR/www
web_server() {
  local ns=$1 ip=$2 name=$3
  mkdir -p "$RUN_DIR/www"
  chmod 755 "$RUN_DIR/www"
  cat > "$RUN_DIR/nginx.conf" <<EOF
worker_processes 1;
pid $RUN_DIR/nginx.pid;
error_log $RUN_DIR/nginx-error.log;
events { worker_connections 64; }
http {
  access_log $RUN_DIR/nginx-access.log;
  default_type application/octet-stream;
  sendfile on;
  server { listen $ip:80; server_name $name; root $RUN_DIR/www; }
}
EOF
  ip netns exec "$ns" nginx -e "$RUN_DIR/nginx-error.log" -c "$RUN_DIR/nginx.conf"
}

# ---------------------------------------------------------------- TLS and web helpers
# pki_init  - a private certificate authority, "Lab Root CA", in $RUN_DIR/pki.
# Clients trust it with: curl --cacert "$PKI/ca.crt"
PKI=""
pki_init() {
  PKI="$RUN_DIR/pki"
  mkdir -p "$PKI/new"
  : > "$PKI/index.txt"
  echo 1000 > "$PKI/serial"
  cat > "$PKI/ca.cnf" <<EOF
[ ca ]
default_ca = lab
[ lab ]
dir = $PKI
database = $PKI/index.txt
serial = $PKI/serial
new_certs_dir = $PKI/new
certificate = $PKI/ca.crt
private_key = $PKI/ca.key
default_md = sha256
policy = anything
unique_subject = no
copy_extensions = none
[ anything ]
commonName = supplied
organizationName = optional
EOF
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$PKI/ca.key" -out "$PKI/ca.crt" \
    -days 3650 -subj "/O=Lab/CN=Lab Root CA" 2>/dev/null
}

# pki_cert <name> <host-name> <valid-from> <valid-until>  - a server certificate signed by
# the lab CA, for one host name, in $PKI/<name>.crt and .key. Dates as "date -d" accepts
# them, for example "-1 year" or "+90 days".
pki_cert() {
  local name=$1 host=$2 from to
  from=$(date -u -d "$3" +%Y%m%d%H%M%SZ)
  to=$(date -u -d "$4" +%Y%m%d%H%M%SZ)
  openssl req -newkey rsa:2048 -nodes -keyout "$PKI/$name.key" -out "$PKI/$name.csr" \
    -subj "/O=Lab/CN=$host" 2>/dev/null
  printf 'subjectAltName = DNS:%s\nbasicConstraints = CA:FALSE\nkeyUsage = digitalSignature, keyEncipherment\nextendedKeyUsage = serverAuth\n' \
    "$host" > "$PKI/$name.ext"
  openssl ca -batch -config "$PKI/ca.cnf" -in "$PKI/$name.csr" -out "$PKI/$name.crt" \
    -startdate "$from" -enddate "$to" -extfile "$PKI/$name.ext" -notext >/dev/null 2>&1 \
    || { echo "!! could not create certificate $name"; exit 1; }
}

# nginx_start <ns> <name> <server blocks...>  - nginx with the given server { } blocks.
# Files are served from $RUN_DIR/www-<name>. Logs go to $RUN_DIR/<name>-*.log.
nginx_start() {
  local ns=$1 name=$2
  shift 2
  mkdir -p "$RUN_DIR/www-$name"
  chmod 755 "$RUN_DIR/www-$name"
  cat > "$RUN_DIR/$name.conf" <<EOF
worker_processes 1;
pid $RUN_DIR/$name.pid;
error_log $RUN_DIR/$name-error.log;
events { worker_connections 64; }
http {
  access_log $RUN_DIR/$name-access.log;
  default_type text/html;
  sendfile on;
  keepalive_timeout 30;
$(printf '  %s\n' "$@")
}
EOF
  ip netns exec "$ns" nginx -e "$RUN_DIR/$name-error.log" -c "$RUN_DIR/$name.conf"
}

# nginx_stop <ns> <name>
nginx_stop() {
  [[ -f "$RUN_DIR/$2.pid" ]] && kill "$(cat "$RUN_DIR/$2.pid")" 2>/dev/null || true
  sleep 0.5
}

# app_server <ns> <ip> <port> <name>  - a small JSON web application (Python).
# Every URL answers at once, except URLs that contain "report", which take as many
# seconds as the file $RUN_DIR/<name>.delay says (default 0). Stop it with app_stop <name>.
app_server() {
  local ns=$1 ip=$2 port=$3 name=$4
  cat > "$RUN_DIR/$name.py" <<'EOF'
import http.server, json, os, sys, time
ip, port, delay_file = sys.argv[1], int(sys.argv[2]), sys.argv[3]
class App(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def do_GET(self):
        if "report" in self.path:
            try: time.sleep(float(open(delay_file).read()))
            except (OSError, ValueError): pass
        body = json.dumps({"path": self.path, "items": list(range(40)),
                           "server": "app", "time": time.strftime("%H:%M:%S")}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try: self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError): pass   # the client gave up waiting
    def log_message(self, *a): pass
class Server(http.server.ThreadingHTTPServer):
    def handle_error(self, request, client_address): pass
Server((ip, port), App).serve_forever()
EOF
  ip netns exec "$ns" python3 "$RUN_DIR/$name.py" "$ip" "$port" "$RUN_DIR/$name.delay" &
  echo $! > "$RUN_DIR/$name.app.pid"
  sleep 1
}

app_stop() {
  [[ -f "$RUN_DIR/$1.app.pid" ]] && kill "$(cat "$RUN_DIR/$1.app.pid")" 2>/dev/null || true
  sleep 0.5
}

# smb_server <ns> <ip> <share-dir>  - a Windows-style file server (Samba) with one read-only
# share, \\<ip>\files, open to guests. Samba runs only inside the namespace.
smb_server() {
  local ns=$1 ip=$2 dir=$3 d="$RUN_DIR/samba"
  # Installing Samba starts it on the VM itself; the lab does not want that
  systemctl disable --now smbd nmbd samba-ad-dc >/dev/null 2>&1 || true
  mkdir -p "$d/private" "$d/lock" "$d/state" "$d/cache" "$d/pid" "$d/ncalrpc"
  chmod -R a+rX "$dir"
  cat > "$d/smb.conf" <<EOF
[global]
  server role = standalone server
  workgroup = LAB
  interfaces = $ip
  bind interfaces only = yes
  smb ports = 445
  disable netbios = yes
  map to guest = Bad User
  server smb encrypt = off
  load printers = no
  printing = bsd
  printcap name = /dev/null
  disable spoolss = yes
  private dir = $d/private
  lock directory = $d/lock
  state directory = $d/state
  cache directory = $d/cache
  pid directory = $d/pid
  ncalrpc dir = $d/ncalrpc
  log file = $RUN_DIR/samba.log
[files]
  path = $dir
  read only = yes
  guest ok = yes
EOF
  # setsid: in its own session, because Samba signals its whole process group when it
  # stops, and that would otherwise include this script
  setsid ip netns exec "$ns" smbd --foreground --no-process-group -s "$d/smb.conf" </dev/null >"$RUN_DIR/smbd.out" 2>&1 &
  sleep 2
}

# ---------------------------------------------------------------- phones (SIPp)
# Each phone uses SIP on port 5060 and sends its audio (RTP, G.711 a-law, the sample that
# comes with SIPp) from port 6000. <sdp-ip> is the address the phone announces in its SDP
# as "send my audio here"; normally its own address.
SIP_AUDIO=/usr/share/sip-tester/g711a.pcap

_sip_xml() {   # _sip_xml <template> <sdp-ip> <name>  - fill in a call script from lab/sip/
  sed -e "s#@SDPIP@#$2#g" -e "s#@PCAP@#$SIP_AUDIO#g" "$LAB_DIR/sip/$1.xml" > "$RUN_DIR/$3.xml"
}

# _rtp_listen <ns> <ip>  - a phone's loudspeaker: receives audio on port 6000 for 40 seconds.
# (SIPp sends audio but does not listen for it; a real phone does, so nothing is "refused".)
_rtp_listen() {
  ip netns exec "$1" timeout 40 python3 -c '
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((sys.argv[1], 6000))
while True: s.recv(2048)' "$2" >/dev/null 2>&1 &
}

# phone_answer <ns> <ip> <sdp-ip> <name>  - a phone that answers one call (in the background)
phone_answer() {
  _rtp_listen "$1" "$2"
  _sip_xml answer "$3" "$4"
  ip netns exec "$1" sipp -sf "$RUN_DIR/$4.xml" -i "$2" -p 5060 -mi "$2" -min_rtp_port 6000 -max_rtp_port 6010 \
    -m 1 -nostdin -trace_err -error_file "$RUN_DIR/$4.err" >"$RUN_DIR/$4.out" 2>&1 &
  echo $! > "$RUN_DIR/$4.pid"
  sleep 1
}

# phone_call <ns> <ip> <sdp-ip> <target-ip> <name>  - a phone that calls 1001 at <target-ip>,
# talks for about 8 seconds and hangs up. Returns SIPp's exit code (0 = call completed).
phone_call() {
  _rtp_listen "$1" "$2"
  _sip_xml caller "$3" "$5"
  timeout 40 ip netns exec "$1" sipp -sf "$RUN_DIR/$5.xml" -s 1001 "$4:5060" -i "$2" -p 5060 \
    -mi "$2" -min_rtp_port 6000 -max_rtp_port 6010 -m 1 -nostdin -trace_err -error_file "$RUN_DIR/$5.err" >"$RUN_DIR/$5.out" 2>&1 \
    || { local rc=$?; echo "!! the call from $5 failed (SIPp exit code $rc):"
         tail -5 "$RUN_DIR/$5.err" "$RUN_DIR/$5.out" 2>/dev/null | grep -v '^$' | sed 's/^/     /'; return $rc; }
}

# phone_wait <name>  - wait until an answering phone has finished its call
phone_wait() {
  local pid; pid=$(cat "$RUN_DIR/$1.pid" 2>/dev/null) || return 0
  for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.5; done
  kill "$pid" 2>/dev/null || true
}

# rtp_report <capture>  - one line per RTP stream: from, to, packets, lost, max jitter
rtp_report() {
  tshark -r "$1" -o rtp.heuristic_rtp:TRUE -q -z rtp,streams 2>/dev/null \
    | awk '$3 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { j = ($NF ~ /^[0-9.]+$/) ? $NF : $(NF-1)
        printf "      %s:%s -> %s:%s  %s packets, lost %s %s, max jitter %s ms\n", $3, $4, $5, $6, $9, $10, $11, j }'
}

# capture_start <ns> <if> <file.pcapng>
# dumpcap drops root's file-permission override after start-up, so it
# writes into the root-owned temp folder first; capture_stop moves the
# finished file into captures/.
CAP_OUT=""
CAP_TMP=""
capture_start() {
  CAP_OUT="$3"
  CAP_TMP="$RUN_DIR/$(basename "$3")"
  rm -f "$CAP_OUT" "$CAP_TMP"
  # CAP_SNAPLEN=<bytes> keeps only the start of each packet (headers), for long captures
  ip netns exec "$1" dumpcap -q -i "$2" ${CAP_SNAPLEN:+-s "$CAP_SNAPLEN"} -w "$CAP_TMP" >"$RUN_DIR/dumpcap.log" 2>&1 &
  CAP_PID=$!
  sleep 2
  if ! kill -0 "$CAP_PID" 2>/dev/null; then
    CAP_PID=""
    echo "!! Capture failed to start. dumpcap said:"
    cat "$RUN_DIR/dumpcap.log"
    exit 1
  fi
}

capture_stop() {
  if [[ -n "$CAP_PID" ]]; then
    sleep 1
    kill -INT "$CAP_PID" 2>/dev/null || true
    wait "$CAP_PID" 2>/dev/null || true
    CAP_PID=""
  fi
  if [[ -n "$CAP_TMP" && -f "$CAP_TMP" ]]; then
    mv "$CAP_TMP" "$CAP_OUT"
    chown "$LAB_USER:$LAB_USER" "$CAP_OUT"
  fi
  CAP_TMP=""
}

# capture2_start <ns> <if> <file.pcapng>  - a second capture point, running alongside the first
# (for example the server side). Start it BEFORE capture_start; stop it after capture_stop.
CAP2_PID=""
CAP2_OUT=""
CAP2_TMP=""
capture2_start() {
  CAP2_OUT="$3"
  CAP2_TMP="$RUN_DIR/second-$(basename "$3")"
  rm -f "$CAP2_OUT" "$CAP2_TMP"
  ip netns exec "$1" dumpcap -q -i "$2" -w "$CAP2_TMP" >"$RUN_DIR/dumpcap2.log" 2>&1 &
  CAP2_PID=$!
  sleep 1
  if ! kill -0 "$CAP2_PID" 2>/dev/null; then
    CAP2_PID=""
    echo "!! Second capture failed to start. dumpcap said:"
    cat "$RUN_DIR/dumpcap2.log"
    exit 1
  fi
}

capture2_stop() {
  if [[ -n "$CAP2_PID" ]]; then
    kill -INT "$CAP2_PID" 2>/dev/null || true
    wait "$CAP2_PID" 2>/dev/null || true
    CAP2_PID=""
  fi
  if [[ -n "$CAP2_TMP" && -f "$CAP2_TMP" ]]; then
    mv "$CAP2_TMP" "$CAP2_OUT"
    chown "$LAB_USER:$LAB_USER" "$CAP2_OUT"
  fi
  CAP2_TMP=""
}

# count <file> <display filter>  - number of packets that match
count() { tshark -r "$1" -Y "$2" 2>/dev/null | wc -l; }

# capture_check <file>  - stop with a clear message if no capture was written
capture_check() {
  if [[ ! -s "$1" ]]; then
    echo "!! No capture written to $1. dumpcap said:"
    cat "$RUN_DIR/dumpcap.log" 2>/dev/null
    exit 1
  fi
}

# tcp_stats <file>  - quick lab check: count TCP problem markers
tcp_stats() {
  local f=$1 k
  for k in retransmission fast_retransmission duplicate_ack lost_segment zero_window; do
    printf "    %-22s %s\n" "$k" "$(tshark -r "$f" -Y "tcp.analysis.$k" 2>/dev/null | wc -l)"
  done
}

# cleanup - stop everything, delete namespaces, fix file ownership
cleanup() {
  set +e
  capture_stop
  capture2_stop
  local ns
  for ns in "${NS_LIST[@]}"; do
    ip netns pids "$ns" 2>/dev/null | xargs -r kill 2>/dev/null
    sleep 0.3
    ip netns del "$ns" 2>/dev/null
    rm -rf "/etc/netns/$ns"
  done
  [[ -n "$RUN_DIR" ]] && rm -rf "$RUN_DIR"
  chown -R "$LAB_USER:$LAB_USER" "$CAP_DIR" 2>/dev/null
  return 0
}
