#!/usr/bin/env bash
# =============================================================
#  Wireshark Troubleshooting Lab Scenarios - lab VM setup
#  Target: Ubuntu Server 24.04 LTS  (VM name: wireshark-lab)
#  Usage:  chmod +x setup-lab.sh && sudo ./setup-lab.sh
#  Safe to run more than once.
# =============================================================
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo:  sudo ./setup-lab.sh"
  exit 1
fi

LAB_USER="${SUDO_USER:-lab}"
LAB_HOME="$(getent passwd "$LAB_USER" | cut -d: -f6)"
LAB_DIR="$LAB_HOME/wireshark-lab"
export DEBIAN_FRONTEND=noninteractive

step() { echo; echo "==> $*"; }

# -------------------------------------------------------------
step "1/6  Allow non-root packet capture (answer the tshark prompt in advance)"
echo "wireshark-common wireshark-common/install-setuid boolean true" | debconf-set-selections

# -------------------------------------------------------------
step "2/6  Install lab packages"
apt-get update -y
apt-get install -y \
  tcpdump tshark \
  iproute2 iptables nftables conntrack bridge-utils ethtool \
  dnsmasq-base bind9-dnsutils \
  nginx openssl curl wget \
  iperf3 netcat-openbsd iputils-ping iputils-arping traceroute \
  samba smbclient dhcpcd-base zip \
  sip-tester \
  python3 python3-scapy nmap hping3 \
  git jq tree

# -------------------------------------------------------------
step "3/6  Stop host services - each scenario starts its own copy inside a namespace"
for svc in nginx smbd nmbd samba-ad-dc; do
  if systemctl cat "${svc}.service" >/dev/null 2>&1; then
    systemctl disable --now "$svc" >/dev/null 2>&1 || true
    echo "    disabled $svc"
  fi
done

# -------------------------------------------------------------
step "4/6  Load netem on every boot"
modprobe sch_netem
echo "sch_netem" > /etc/modules-load.d/netem.conf

# -------------------------------------------------------------
step "5/6  Capture permissions and lab folders"
usermod -aG wireshark "$LAB_USER"
mkdir -p "$LAB_DIR"/{lib,scenarios,captures,configs,keys}
chown -R "$LAB_USER:$LAB_USER" "$LAB_DIR"

# -------------------------------------------------------------
step "6/6  Version report"
{
  echo "Lab setup completed: $(date '+%Y-%m-%d %H:%M')"
  echo "OS:       $(lsb_release -ds 2>/dev/null)"
  echo "Kernel:   $(uname -r)"
  echo "tshark:   $(tshark --version 2>/dev/null | head -1)"
  echo "tcpdump:  $(tcpdump --version 2>&1 | head -1)"
  echo "nginx:    $(nginx -v 2>&1)"
  echo "openssl:  $(openssl version)"
  echo "dnsmasq:  $(dnsmasq --version | head -1)"
  echo "samba:    $(smbd --version)"
  echo "sipp:     $(sipp -v 2>&1 | grep -m1 -i sipp || echo installed)"
  echo "scapy:    $(python3 -c 'import scapy; print(scapy.__version__)')"
  echo "nmap:     $(nmap --version | head -1)"
  echo "iperf3:   $(iperf3 --version | head -1)"
} | tee "$LAB_DIR/versions.txt"
chown "$LAB_USER:$LAB_USER" "$LAB_DIR/versions.txt"

echo
echo "Done. Log out and back in so '$LAB_USER' joins the wireshark group."
echo "Lab folder: $LAB_DIR"
