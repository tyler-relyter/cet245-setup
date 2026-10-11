#!/usr/bin/env bash
# =============================================================================
#  CET 245 - Internet Servers  |  Ubuntu Client (Desktop) catch-up script
#  Covers the client side of Labs 1-5:
#     Lab 2  install ssh
#     Lab 3  static address 10.0.2.15/24 (the "Wired Settings" step, done with nmcli)
#     Lab 5  use the server (10.0.2.5) as the DNS server; install dig
#
#  Run ON THE UBUNTU CLIENT VM, in a Terminal, AFTER the server script:
#      sudo bash cet245_client_setup.sh
#      sudo bash cet245_client_setup.sh --check     # verify only, change nothing
#
#  The client gets its DNS from the server's BIND. If the server isn't
#  answering DNS yet, the script adds 1.1.1.1 as a temporary second DNS
#  server so the client keeps working; re-run it once the server is done.
#  Log: /var/log/cet245-setup.log
# =============================================================================
set -Eeuo pipefail

# ----------------------------- course values ---------------------------------
DOMAIN="classroom.edu"
CLIENT_HOSTNAME="client"
CLIENT_IP="10.0.2.15"
SERVER_IP="10.0.2.5"
PREFIX="24"
GATEWAY="auto"      # "auto" = keep the gateway DHCP gave this VM. Lab 3 says 10.0.2.2.
TEMP_DNS="1.1.1.1"  # only used if the server's DNS isn't answering yet
IFACE="auto"
# -----------------------------------------------------------------------------

LOG=/var/log/cet245-setup.log
CHECK_ONLY=0
case "${1:-}" in
  --check) CHECK_ONLY=1 ;;
  -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "") ;;
  *) echo "Unknown option: $1"; exit 1 ;;
esac

c_ok=$'\e[32m'; c_warn=$'\e[33m'; c_err=$'\e[31m'; c_h=$'\e[1;34m'; c_0=$'\e[0m'
say()  { echo "${c_h}==>${c_0} $*" | tee -a "$LOG"; }
ok()   { echo "  ${c_ok}[ok]${c_0}   $*" | tee -a "$LOG"; }
warn() { echo "  ${c_warn}[warn]${c_0} $*" | tee -a "$LOG"; }
die()  { echo "  ${c_err}[fail]${c_0} $*" | tee -a "$LOG"; exit 1; }
trap 'die "line $LINENO: \"$BASH_COMMAND\" failed - see $LOG"' ERR
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else warn "NOT OK: $d"; fi; }

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo bash $0"; exit 1; }
command -v nmcli >/dev/null || die "nmcli not found - this script expects Ubuntu Desktop (NetworkManager)."
echo "---- $(date) : client check=$CHECK_ONLY ----" >> "$LOG"

if [[ "$IFACE" == auto ]]; then
  IFACE=$(ip -o -4 route show default 2>/dev/null | awk '{print $5; exit}')
  [[ -n "$IFACE" ]] || IFACE=$(nmcli -t -f DEVICE,TYPE device | awk -F: '$2=="ethernet"{print $1; exit}')
fi
if [[ "$GATEWAY" == auto ]]; then
  GATEWAY=$(ip -o -4 route show default 2>/dev/null | awk '{print $3; exit}')
  [[ -n "$GATEWAY" ]] || GATEWAY="10.0.2.2"
fi

server_dns_ok() { dig +short +time=2 +tries=1 @"$SERVER_IP" "server.$DOMAIN" 2>/dev/null | grep -qx "$SERVER_IP"; }

verify() {
  say "Verification"
  check "hostname is $CLIENT_HOSTNAME" test "$(hostname)" = "$CLIENT_HOSTNAME"
  check "ssh installed" dpkg -s openssh-client
  check "$IFACE has $CLIENT_IP/$PREFIX" bash -c "ip -4 addr show $IFACE | grep -q '$CLIENT_IP/$PREFIX'"
  check "server reachable (ping $SERVER_IP)" ping -c 2 -W 2 "$SERVER_IP"
  check "server SSH port open" timeout 3 bash -c "</dev/tcp/$SERVER_IP/22"
  check "server DNS answers (dig @$SERVER_IP server.$DOMAIN)" server_dns_ok
  check "system resolver finds $DOMAIN (dig $DOMAIN)" bash -c "dig +short $DOMAIN | grep -qx '$SERVER_IP'"
  check "internet names resolve (dig ubuntu.com)" bash -c "dig +short ubuntu.com | grep -q ."
  say "Log: $LOG"
}
if [[ $CHECK_ONLY -eq 1 ]]; then verify; exit 0; fi

say "Using interface $IFACE, gateway $GATEWAY"

# --------------------- Lab 2: packages (before the IP changes) ---------------
say "Lab 2 - install ssh (and dig for Lab 5)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q >>"$LOG" 2>&1
apt-get install -y -q ssh dnsutils >>"$LOG" 2>&1
ok "installed: ssh dnsutils"
if [[ "$(hostname)" != "$CLIENT_HOSTNAME" ]]; then
  hostnamectl set-hostname "$CLIENT_HOSTNAME"; ok "hostname set to $CLIENT_HOSTNAME"
else ok "hostname already $CLIENT_HOSTNAME"; fi

# --------------------- Lab 3 + Lab 5: static IP and DNS ----------------------
say "Lab 3 - static address $CLIENT_IP/$PREFIX;  Lab 5 - DNS $SERVER_IP"
CON=$(nmcli -g GENERAL.CONNECTION device show "$IFACE" 2>/dev/null || true)
[[ -n "$CON" ]] || die "no NetworkManager connection on $IFACE - open Settings > Network and turn Wired on, then re-run"
ok "connection: \"$CON\""

DNS_LIST="$SERVER_IP"
if server_dns_ok; then
  ok "server DNS is answering"
else
  DNS_LIST="$SERVER_IP $TEMP_DNS"
  warn "server DNS not answering yet - adding $TEMP_DNS as a temporary second DNS server"
  warn "re-run this script after the server script finishes to remove it"
fi

nmcli connection modify "$CON" \
  ipv4.method manual \
  ipv4.addresses "$CLIENT_IP/$PREFIX" \
  ipv4.gateway "$GATEWAY" \
  ipv4.dns "$DNS_LIST" \
  ipv4.ignore-auto-dns yes
nmcli connection up "$CON" >>"$LOG" 2>&1
sleep 3
ok "IPv4: manual, $CLIENT_IP/$PREFIX, gateway $GATEWAY, DNS $DNS_LIST"

verify
say "Done. Take a VirtualBox snapshot of the client now."
