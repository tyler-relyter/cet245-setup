#!/usr/bin/env bash
# shellcheck disable=SC2088  # "~/" in messages is text, not a path
# =============================================================================
#  CET 245 - Internet Servers  |  Ubuntu Client (Desktop) catch-up / repair
#  Covers the client side of Labs 2-10:
#     Lab 2   install ssh
#     Lab 3   static address 10.0.2.15/24 (the "Wired Settings" step, done with nmcli)
#     Lab 5   use the server (10.0.2.5) as the DNS server; install dig
#     Lab 6   hosts entry for classroom.edu, key pair key-student-server,
#             ~/.ssh/config "Host server", key copied to the server, test files
#     Lab 8   lynx for testing the web server
#     Lab 10  checks that https://classroom.edu answers (self-signed certificate)
#
#  Run ON THE UBUNTU CLIENT VM, in a Terminal, AFTER the server script:
#      sudo bash cet245_client_setup.sh
#      sudo bash cet245_client_setup.sh --check              # verify only, change nothing
#      sudo bash cet245_client_setup.sh --server-user NAME   # server account (default student)
#
#  The SSH steps are done for the desktop user who ran sudo. The client gets
#  its DNS from the server's BIND. If the server doesn't answer DNS yet, or
#  answers classroom.edu but not internet names, the script adds 1.1.1.1 as a
#  temporary second DNS server; re-run it once the server is fixed. Before
#  installing anything it disables a leftover installer (cdrom) package source
#  and checks that names resolve (repairing /etc/resolv.conf if needed), and
#  after the network change it confirms that names still resolve.
#  Safe to re-run. Log: /var/log/cet245-setup.log
# =============================================================================
set -Eeuo pipefail

# ----------------------------- course values ---------------------------------
DOMAIN="classroom.edu"
CLIENT_HOSTNAME="client"
CLIENT_IP="10.0.2.15"
SERVER_IP="10.0.2.5"
SERVER_FQDN="server.$DOMAIN"
SERVER_USER="student"          # account on the server (--server-user to change)
LAB_PASSWORD="Password01"      # used once, to copy the SSH key to the server
PREFIX="24"
GATEWAY="auto"      # "auto" = keep the gateway DHCP gave this VM. Lab 3 says 10.0.2.2.
TEMP_DNS="1.1.1.1"  # only used if the server's DNS isn't answering yet
IFACE="auto"
KEY_NAME="key-student-server"  # Lab 6 step 9
# -----------------------------------------------------------------------------

LOG=/var/log/cet245-setup.log
CHECK_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK_ONLY=1; shift ;;
    --server-user) SERVER_USER="$2"; shift 2 ;;
    -h|--help) sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

c_ok=$'\e[32m'; c_warn=$'\e[33m'; c_err=$'\e[31m'; c_h=$'\e[1;34m'; c_0=$'\e[0m'
say()  { echo "${c_h}==>${c_0} $*" | tee -a "$LOG"; }
ok()   { echo "  ${c_ok}[ok]${c_0}   $*" | tee -a "$LOG"; }
warn() { echo "  ${c_warn}[warn]${c_0} $*" | tee -a "$LOG"; }
die()  { echo "  ${c_err}[fail]${c_0} $*" | tee -a "$LOG"; exit 1; }
trap 'die "line $LINENO: \"$BASH_COMMAND\" failed - see $LOG"' ERR
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else warn "NOT OK: $d"; fi; }
BACKUP_DIR="/var/backups/cet245/$(date +%Y%m%d-%H%M%S)"
backup() {   # copy a file into this run's backup folder before it is changed
  [[ -e "$1" || -L "$1" ]] || return 0
  mkdir -p "$BACKUP_DIR$(dirname "$1")"
  cp -aP "$1" "$BACKUP_DIR$1"
}

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo bash $0"; exit 1; }
command -v nmcli >/dev/null || die "nmcli not found - this script expects Ubuntu Desktop (NetworkManager)."
echo "---- $(date) : client check=$CHECK_ONLY server-user=$SERVER_USER ----" >> "$LOG"

if [[ "$IFACE" == auto ]]; then
  IFACE=$(ip -o -4 route show default 2>/dev/null | awk '{print $5; exit}')
  [[ -n "$IFACE" ]] || IFACE=$(nmcli -t -f DEVICE,TYPE device | awk -F: '$2=="ethernet"{print $1; exit}')
fi
if [[ "$GATEWAY" == auto ]]; then
  GATEWAY=$(ip -o -4 route show default 2>/dev/null | awk '{print $3; exit}')
  [[ -n "$GATEWAY" ]] || GATEWAY="10.0.2.2"
fi

# The desktop user (the person who ran sudo) owns the SSH keys and config.
DUSER="${SUDO_USER:-}"
if [[ -z "$DUSER" || "$DUSER" == root ]]; then
  DUSER=$(getent passwd | awk -F: '$3>=1000 && $3<60000 {print $1; exit}' || true)
fi
[[ -n "$DUSER" ]] || die "could not find the desktop user - run with sudo from your own account"
DHOME=$(getent passwd "$DUSER" | cut -d: -f6 || true)
KEY="$DHOME/.ssh/$KEY_NAME"
as_user() { sudo -u "$DUSER" -H "$@"; }
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new)

# hosts_maps NAME... : true if /etc/hosts has a $SERVER_IP line listing every NAME
hosts_maps() { awk -v ip="$SERVER_IP" -v names="$*" '
  BEGIN { n = split(names, want, " ") }
  $1 == ip { for (i = 2; i <= NF; i++) seen[$i] = 1 }
  END { for (j = 1; j <= n; j++) if (!(want[j] in seen)) exit 1 }' /etc/hosts; }
server_dns_ok() { dig +short +time=2 +tries=1 @"$SERVER_IP" "$SERVER_FQDN" 2>/dev/null | grep -qx "$SERVER_IP"; }
# no_temp_dns : the wired connection's DNS list no longer holds the temporary server
no_temp_dns() {
  local con; con=$(nmcli -g GENERAL.CONNECTION device show "$IFACE" 2>/dev/null || true)
  [[ -n "$con" ]] && ! nmcli -g ipv4.dns connection show "$con" 2>/dev/null | grep -qF "$TEMP_DNS"
}
# server_recursion_ok : the server's BIND also answers internet names (Lab 5 forwarders)
server_recursion_ok() { dig +short +time=3 +tries=1 @"$SERVER_IP" "$INET_TEST_NAME" 2>/dev/null | grep -qE '^[0-9.]+$'; }
FALLBACK_DNS=("$TEMP_DNS" "8.8.8.8")    # temporary DNS if names fail
# ===================== preflight: package sources and DNS ====================
# Both VMs need working name resolution before apt can install anything, and a
# VM that pings 8.8.8.8 but can't resolve names fails every later lab. These
# helpers find out where resolution breaks and repair what they safely can.
INET_TEST_NAME="archive.ubuntu.com"     # a name apt needs anyway

# names_ok [NAME] : resolves through the system resolver, the way ping and apt do
names_ok() { getent ahostsv4 "${1:-$INET_TEST_NAME}" >/dev/null 2>&1; }

# resolv_ok : /etc/resolv.conf is systemd-resolved's file (Ubuntu's default)
resolv_ok() {
  local t; t=$(readlink -f /etc/resolv.conf 2>/dev/null || true)
  [[ "$t" == /run/systemd/resolve/stub-resolv.conf || "$t" == /run/systemd/resolve/resolv.conf ]]
}

# dns_servers : the DNS servers systemd-resolved is using, one per line
dns_servers() {
  resolvectl dns 2>/dev/null | sed 's/^[^:]*://' | tr ' ' '\n' | grep -E '^[0-9]+(\.[0-9]+){3}$' | sort -u || true
}

# dns_report : explain where name resolution breaks, one line per DNS server
dns_report() {
  local s n=0
  say "Name resolution report"
  if resolv_ok; then ok "/etc/resolv.conf -> $(readlink -f /etc/resolv.conf)"
  else warn "/etc/resolv.conf is not systemd-resolved's file ($(readlink -f /etc/resolv.conf 2>/dev/null || echo missing))"; fi
  systemctl is-active --quiet systemd-resolved && ok "systemd-resolved running" || warn "systemd-resolved is not running"
  for s in $(dns_servers); do
    n=$((n + 1))
    if ! command -v dig >/dev/null; then ok "DNS server in use: $s"; continue; fi
    if dig +short +time=2 +tries=1 @"$s" "$INET_TEST_NAME" 2>/dev/null | grep -qE '^[0-9.]+$'; then
      ok "DNS server $s answers internet names"
    else
      warn "DNS server $s does NOT answer internet names ($INET_TEST_NAME)"
    fi
  done
  [[ $n -gt 0 ]] || warn "no DNS servers configured (resolvectl dns lists none)"
  if command -v dig >/dev/null; then
    if dig +short +time=2 +tries=1 @1.1.1.1 "$INET_TEST_NAME" 2>/dev/null | grep -qE '^[0-9.]+$'; then
      ok "public DNS 1.1.1.1 reachable - the problem is the DNS server(s) above, not the network"
    else
      warn "public DNS 1.1.1.1 not reachable either - outbound DNS (port 53) is blocked or there is no internet"
    fi
  fi
}

# fix_resolver : make sure systemd-resolved runs and /etc/resolv.conf points at it
# (students sometimes edit or replace /etc/resolv.conf, or link it to a typo).
fix_resolver() {
  if [[ ! -e /usr/lib/systemd/system/systemd-resolved.service && ! -e /lib/systemd/system/systemd-resolved.service ]]; then
    warn "systemd-resolved is not installed - leaving /etc/resolv.conf alone"; return 0
  fi
  if ! systemctl is-active --quiet systemd-resolved; then
    systemctl enable --now systemd-resolved >>"$LOG" 2>&1 && ok "systemd-resolved started"
  fi
  if ! resolv_ok; then
    if [[ -e /etc/resolv.conf || -L /etc/resolv.conf ]]; then backup /etc/resolv.conf; fi
    ln -sfn ../run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    ok "/etc/resolv.conf linked back to systemd-resolved (old copy in $BACKUP_DIR)"
  fi
  resolvectl flush-caches >/dev/null 2>&1 || true
}

# disable_cdrom_sources : the installer ISO is left as a package source
# ("file:/cdrom ... no longer has a Release file"), which makes apt update fail.
disable_cdrom_sources() {
  local f changed=0 tmp
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
    [[ -f "$f" ]] || continue
    grep -qE '^[[:space:]]*deb(-src)?[[:space:]].*(cdrom:|file:/+cdrom)' "$f" || continue
    backup "$f"
    sed -i -E 's/^([[:space:]]*deb(-src)?[[:space:]].*(cdrom:|file:\/+cdrom).*)$/# \1/' "$f"
    ok "disabled the installer cdrom source in $f"; changed=1
  done
  for f in /etc/apt/sources.list.d/*.sources; do
    [[ -f "$f" ]] || continue
    grep -qiE '^URIs:.*(cdrom:|file:/+cdrom)' "$f" || continue
    tmp=$(mktemp)
    # deb822 format: add "Enabled: no" to each stanza whose URIs point at the cdrom.
    awk '
      function flush(   i) {
        for (i = 1; i <= n; i++) if (!(cd && tolower(L[i]) ~ /^enabled:/)) print L[i]
        if (cd) print "Enabled: no"
        n = 0; cd = 0
      }
      /^[ \t]*$/ { flush(); print; next }
      { L[++n] = $0; if (tolower($0) ~ /^uris:/ && ($0 ~ /cdrom:/ || $0 ~ /file:\/+cdrom/)) cd = 1 }
      END { flush() }' "$f" > "$tmp"
    if cmp -s "$tmp" "$f"; then rm -f "$tmp"; continue; fi   # already disabled
    backup "$f"
    cat "$tmp" > "$f"; rm -f "$tmp"
    ok "disabled the installer cdrom source in $f"; changed=1
  done
  [[ $changed -eq 1 ]] || ok "package sources OK (no installer cdrom entry)"
}

# apt_update : apt-get update that shows apt's own error lines if it fails
apt_update() {
  if apt-get update -q >>"$LOG" 2>&1; then ok "apt-get update"; return 0; fi
  tail -n 40 "$LOG" | grep -E '^(E|Err):' | sort -u | sed 's/^/        /' || true
  die "apt-get update failed - the errors above come from apt (full log: $LOG)"
}

# preflight_network : sources, internet by IP, then names; repair names if needed
preflight_network() {
  say "Preflight - package sources, internet, name resolution"
  disable_cdrom_sources
  local ip_ok=1
  if ping -c 2 -W 2 8.8.8.8 >/dev/null 2>&1; then ok "internet reachable by IP (ping 8.8.8.8)"
  else ip_ok=0; warn "cannot ping 8.8.8.8 (some networks block ping; checking names anyway)"; fi
  if names_ok; then ok "name resolution works (getent $INET_TEST_NAME)"; return 0; fi
  if [[ $ip_ok -eq 0 ]]; then
    warn "no ping and no names: the VM probably has no internet - check its network adapter, NAT Network and gateway ($GATEWAY)"
  else
    warn "ping by IP works but names do not resolve - repairing DNS"
  fi
  fix_resolver
  if names_ok; then ok "name resolution works after the resolver fix"; return 0; fi
  dns_report
  # Last resort so the installs can run: a temporary DNS server on the interface.
  # It is runtime only (gone after a reboot); the lab steps below set the real DNS.
  if resolvectl dns "$IFACE" "${FALLBACK_DNS[@]}" >>"$LOG" 2>&1; then
    resolvectl flush-caches >/dev/null 2>&1 || true
    sleep 1
  fi
  if names_ok; then ok "temporary DNS ${FALLBACK_DNS[*]} on $IFACE lets installs run (cleared on reboot)"
  else warn "names still do not resolve, even through ${FALLBACK_DNS[*]} - apt will fail; see the report above"; fi
}

key_login_ok()  { as_user ssh "${SSH_OPTS[@]}" -i "$KEY" "$SERVER_USER@$SERVER_FQDN" true 2>/dev/null; }
https_code()    { curl -sk --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 5 "https://$DOMAIN/" 2>/dev/null || true; }

verify() {
  say "Verification"
  check "hostname is $CLIENT_HOSTNAME" test "$(hostname)" = "$CLIENT_HOSTNAME"
  check "ssh installed" dpkg -s openssh-client
  check "$IFACE has $CLIENT_IP/$PREFIX" bash -c "ip -4 addr show $IFACE | grep -q '$CLIENT_IP/$PREFIX'"
  check "internet reachable by IP (ping 8.8.8.8)" ping -c 2 -W 2 8.8.8.8
  check "internet names resolve - what ping and apt use (getent $INET_TEST_NAME)" names_ok
  check "ping google.com works" ping -c 2 -W 2 google.com
  check "/etc/resolv.conf is managed by systemd-resolved" resolv_ok
  check "server reachable (ping $SERVER_IP)" ping -c 2 -W 2 "$SERVER_IP"
  check "server SSH port open" timeout 3 bash -c "</dev/tcp/$SERVER_IP/22"
  check "server DNS answers $DOMAIN names (dig @$SERVER_IP $SERVER_FQDN)" server_dns_ok
  check "server DNS answers internet names (dig @$SERVER_IP $INET_TEST_NAME)" server_recursion_ok
  check "system resolver finds $DOMAIN (dig $DOMAIN)" bash -c "dig +short $DOMAIN | grep -qx '$SERVER_IP'"
  check "only the server is used for DNS (no temporary $TEMP_DNS left)" no_temp_dns
  names_ok || dns_report
  check "Lab 6: /etc/hosts maps $DOMAIN to $SERVER_IP" hosts_maps "$DOMAIN"
  check "Lab 6: key pair ~/.ssh/$KEY_NAME exists" test -s "$KEY" -a -s "$KEY.pub"
  check "Lab 6: ~/.ssh/config has Host server with IdentityFile" bash -c "grep -q '^Host server' '$DHOME/.ssh/config' && grep -q 'IdentityFile.*$KEY_NAME' '$DHOME/.ssh/config'"
  check "Lab 6: key login works (ssh server)" key_login_ok
  check "Lab 6: for-transfer.txt copied to ~/Downloads" test -s "$DHOME/Downloads/for-transfer.txt"
  check "Lab 8: lynx installed" command -v lynx
  check "Lab 8-9: web site answers on http://$DOMAIN" bash -c "curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 5 http://$DOMAIN/ | grep -qE '^(200|301)$'"
  check "Lab 10: https://$DOMAIN answers (self-signed certificate)" bash -c "[[ \$(curl -sk --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 5 https://$DOMAIN/) == 200 ]]"
  say "Log: $LOG"
}
if [[ $CHECK_ONLY -eq 1 ]]; then verify; exit 0; fi

say "Using interface $IFACE, gateway $GATEWAY, desktop user $DUSER, server account $SERVER_USER"

# --------------------- Lab 2: packages (before the IP changes) ---------------
say "Lab 2 - install ssh (plus dig for Lab 5, lynx for Lab 8)"
export DEBIAN_FRONTEND=noninteractive
preflight_network
apt_update
apt-get install -y -q ssh dnsutils lynx curl >>"$LOG" 2>&1
ok "installed: ssh dnsutils lynx curl"
if apt-cache policy sshpass 2>/dev/null | grep -q 'Candidate: [0-9]'; then
  apt-get install -y -q sshpass >>"$LOG" 2>&1 && ok "installed: sshpass (copies the key without a password prompt)"
fi
if [[ "$(hostname)" != "$CLIENT_HOSTNAME" ]]; then
  hostnamectl set-hostname "$CLIENT_HOSTNAME"; ok "hostname set to $CLIENT_HOSTNAME"
else ok "hostname already $CLIENT_HOSTNAME"; fi

# --------------------- Lab 3 + Lab 5: static IP and DNS ----------------------
say "Lab 3 - static address $CLIENT_IP/$PREFIX;  Lab 5 - DNS $SERVER_IP"
CON=$(nmcli -g GENERAL.CONNECTION device show "$IFACE" 2>/dev/null || true)
[[ -n "$CON" ]] || die "no NetworkManager connection on $IFACE - open Settings > Network and turn Wired on, then re-run"
ok "connection: \"$CON\""

DNS_LIST="$SERVER_IP"
if server_dns_ok && server_recursion_ok; then
  ok "server DNS answers both $DOMAIN and internet names"
elif server_dns_ok; then
  DNS_LIST="$SERVER_IP $TEMP_DNS"
  warn "server DNS answers $DOMAIN but NOT internet names (BIND forwarders/recursion, Lab 5)"
  warn "adding $TEMP_DNS as a temporary second DNS server; on the server run: sudo bash cet245_server_setup.sh --check"
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
ok "IPv4: manual, $CLIENT_IP/$PREFIX, gateway $GATEWAY, DNS $DNS_LIST"
# Confirm names still resolve with the new settings (wait up to ~10 s).
for _ in 1 2 3 4 5; do names_ok && break; sleep 2; done
if ! names_ok; then
  warn "names do not resolve with the new DNS settings - repairing"
  fix_resolver
fi
if ! names_ok && [[ "$DNS_LIST" != *"$TEMP_DNS"* ]]; then
  DNS_LIST="$SERVER_IP $TEMP_DNS"
  nmcli connection modify "$CON" ipv4.dns "$DNS_LIST"
  nmcli connection up "$CON" >>"$LOG" 2>&1
  for _ in 1 2 3 4 5; do names_ok && break; sleep 2; done
  warn "added $TEMP_DNS as a temporary second DNS server - fix the server's DNS, then re-run"
fi
if names_ok; then ok "name resolution works ($INET_TEST_NAME)"
else warn "name resolution still fails - see the report below"; dns_report; fi

# --------------------- Lab 6: hosts, keys, ssh config -------------------------
say "Lab 6 - /etc/hosts entry for $DOMAIN (step 5)"
if hosts_maps "$DOMAIN" "$SERVER_FQDN"; then
  ok "/etc/hosts already maps $DOMAIN and $SERVER_FQDN to $SERVER_IP"
else
  cp -a /etc/hosts "/etc/hosts.cet245-$(date +%Y%m%d-%H%M%S)"
  awk -v ip="$SERVER_IP" '$1 != ip' /etc/hosts > /etc/hosts.cet245-new && cat /etc/hosts.cet245-new > /etc/hosts && rm -f /etc/hosts.cet245-new
  echo "$SERVER_IP $DOMAIN $SERVER_FQDN" >> /etc/hosts
  ok "/etc/hosts: $SERVER_IP $DOMAIN $SERVER_FQDN (old copy saved beside it)"
fi

say "Lab 6 - key pair, ~/.ssh/config and the server's host key (steps 6, 9, 10)"
install -d -m 700 -o "$DUSER" -g "$(id -gn "$DUSER")" "$DHOME/.ssh"
if [[ -s "$KEY" && -s "$KEY.pub" ]]; then ok "~/.ssh/$KEY_NAME already exists - kept"
else
  rm -f "$KEY" "$KEY.pub"
  as_user ssh-keygen -q -f "$KEY" -N "" -C "$DUSER@$CLIENT_HOSTNAME" >>"$LOG" 2>&1
  ok "generated ~/.ssh/$KEY_NAME (no passphrase)"
fi
CFG="$DHOME/.ssh/config"
touch "$CFG"
# Replace any existing "Host server" stanza with the Lab 6 version.
TMPC=$(mktemp)
awk '/^[Hh]ost[[:space:]]/{skip = ($2 == "server")} !skip{print}' "$CFG" > "$TMPC"
if [[ -s "$TMPC" && -n "$(tail -c1 "$TMPC")" ]]; then echo >> "$TMPC"; fi   # end the last line
if [[ -s "$TMPC" ]] && [[ -n "$(tail -n1 "$TMPC")" ]]; then echo >> "$TMPC"; fi # blank line between hosts
printf 'Host server\n    HostName %s\n    User %s\n    IdentityFile ~/.ssh/%s\n' \
  "$SERVER_FQDN" "$SERVER_USER" "$KEY_NAME" >> "$TMPC"
if cmp -s "$TMPC" "$CFG"; then ok "~/.ssh/config already has the Host server entry"
else cp -a "$CFG" "$CFG.cet245-bak" 2>/dev/null || true; cat "$TMPC" > "$CFG"; ok "~/.ssh/config: Host server -> $SERVER_USER@$SERVER_FQDN, IdentityFile ~/.ssh/$KEY_NAME"; fi
rm -f "$TMPC"
chown "$DUSER:$(id -gn "$DUSER")" "$CFG"; chmod 600 "$CFG"
# A rebuilt server has new host keys; drop the old ones so ssh doesn't refuse.
for h in "$SERVER_FQDN" "$DOMAIN" "$SERVER_IP"; do
  as_user ssh-keygen -R "$h" >/dev/null 2>&1 || true
done
if as_user bash -c "ssh-keyscan -T 5 '$SERVER_FQDN' '$DOMAIN' '$SERVER_IP' 2>/dev/null >> ~/.ssh/known_hosts"; then
  ok "server host keys refreshed in ~/.ssh/known_hosts"
fi

say "Lab 6 - copy the key to $SERVER_USER@$SERVER_FQDN (step 9)"
if key_login_ok; then
  ok "key login already works"
elif command -v sshpass >/dev/null && as_user env SSHPASS="$LAB_PASSWORD" sshpass -e \
       ssh-copy-id -i "$KEY.pub" -o StrictHostKeyChecking=accept-new "$SERVER_USER@$SERVER_FQDN" >>"$LOG" 2>&1; then
  ok "key copied with ssh-copy-id"
else
  warn "could not copy the key automatically. Run this yourself (password $LAB_PASSWORD):"
  warn "    ssh-copy-id -i ~/.ssh/$KEY_NAME.pub $SERVER_USER@$SERVER_FQDN"
fi

if key_login_ok; then
  say "Lab 6 - copy for-transfer.txt from the server (steps 7-8)"
  if as_user scp -q "${SSH_OPTS[@]}" -i "$KEY" "$SERVER_USER@$SERVER_FQDN:~/for-transfer.txt" "$DHOME/" 2>>"$LOG" \
     && as_user mkdir -p "$DHOME/Downloads" \
     && as_user cp "$DHOME/for-transfer.txt" "$DHOME/Downloads/"; then
    ok "for-transfer.txt copied to ~ and ~/Downloads"
  else warn "for-transfer.txt not found on the server - run the server script with Lab 6 first"; fi
fi

# --------------------- Lab 8-10: web checks -----------------------------------
say "Labs 8-10 - web server from the client"
code=$(https_code)
if [[ "$code" == 200 ]]; then ok "https://$DOMAIN answers (Firefox will warn about the self-signed certificate; that is expected)"
else warn "https://$DOMAIN did not answer yet (code ${code:-none}) - run the server script through Lab 10"; fi

verify
say "Done. Take a snapshot of the client now."
