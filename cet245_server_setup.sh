#!/usr/bin/env bash
# =============================================================================
#  CET 245 - Internet Servers  |  Ubuntu Server catch-up / repair script
#  Brings a server VM to the end state of any lab from 2 through 10:
#     Lab 2  base tools, hostname, SSH          Lab 7  ntp, at, cron jobs
#     Lab 3  static IP, nftables, fail2ban      Lab 8  Apache, then Nginx
#     Lab 4  users, groups, ACLs, sudo          Lab 9  PHP-FPM virtual host
#     Lab 5  DNS with BIND9                     Lab 10 self-signed TLS (HTTPS)
#     Lab 6  sshd hardening, UFW, SSH config
#
#  Run ON THE UBUNTU SERVER VM, as root:
#      sudo bash cet245_server_setup.sh                 # Labs 2 through 10
#      sudo bash cet245_server_setup.sh --through 5     # Labs 2-5 only
#      sudo bash cet245_server_setup.sh --from 6        # VM is fine through 5: do 6-10
#      sudo bash cet245_server_setup.sh --labs 8,9      # only the labs listed
#      sudo bash cet245_server_setup.sh --check         # verify only, change nothing
#      Extra options: --user NAME (lab account, default student)
#                     --name "First Last" (name on created web pages/files)
#
#  If Lab 3 is included, run it from the VM's console window, NOT over SSH:
#  Lab 3 changes the server's IP address, which drops SSH sessions.
#  --from 6 is safe to run over SSH.
#
#  Lab 1 (VirtualBox/Proxmox, ISOs, NAT Network) happens on the host and is
#  covered in the companion guide. Run cet245_client_setup.sh on the client
#  AFTER this script.
#
#  Safe to re-run: each step checks before it changes anything. Any file it
#  replaces is copied to /var/backups/cet245/<date-time>/ first, and files a
#  student writes by hand (index.html, info.php, for-transfer.txt) are only
#  created when missing, never overwritten.
#  Log: /var/log/cet245-setup.log
# =============================================================================
set -Eeuo pipefail

# ----------------------------- course values ---------------------------------
DOMAIN="classroom.edu"
SERVER_HOSTNAME="server"
SERVER_IP="10.0.2.5"
PREFIX="24"
NETWORK_CIDR="10.0.2.0/24"
REVERSE_ZONE="2.0.10.in-addr.arpa"      # reverse of 10.0.2.x
GATEWAY="auto"      # "auto" = keep the gateway DHCP gave this VM. Lab 3 says 10.0.2.2.
UPSTREAM_DNS=("1.1.1.1" "1.0.0.1" "8.8.8.8")
LAB_PASSWORD="Password01"                # course lab password - lab VMs only
IFACE="auto"        # "auto" = interface that holds the default route (enp0s3 on VirtualBox, ens18 on Proxmox)
STUDENT_USER="student"                   # the lab account from Lab 1 (--user to change)
STUDENT_NAME=""                          # --name; default comes from the account's full name
ADMIN_MAIL="admin@$DOMAIN"               # Lab 7 mail recipient
WEB_USER="webdev"                        # Lab 8
SITE_FQDN="server.$DOMAIN"               # Lab 9 default virtual host
SITE_USER="www-server"                   # Lab 9 PHP-FPM pool user
SITE_DIR="/srv/www/$SITE_FQDN"
FPM_PORT="9000"
TLS_CRT="/etc/ssl/certs/classroom.crt"   # Lab 10
TLS_KEY="/etc/ssl/private/classroom.key"
TLS_SUBJ="/C=US/ST=NC/L=Wilmington/O=CFCC/OU=IT/CN=$DOMAIN"
# -----------------------------------------------------------------------------

LAST_LAB=10
LOG=/var/log/cet245-setup.log
STATE=/var/lib/cet245                    # lab<N>.done markers
BACKUP_DIR="/var/backups/cet245/$(date +%Y%m%d-%H%M%S)"
LABS=$(seq -s, 2 "$LAST_LAB")
CHECK_ONLY=0

usage() { sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --through) LABS=$(seq -s, 2 "$2"); shift 2 ;;
    --from)    LABS=$(seq -s, "$2" "$LAST_LAB"); shift 2 ;;
    --labs)    LABS="$2"; shift 2 ;;
    --check)   CHECK_ONLY=1; shift ;;
    --user)    STUDENT_USER="$2"; shift 2 ;;
    --name)    STUDENT_NAME="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

# --------------------------------- helpers -----------------------------------
c_ok=$'\e[32m'; c_warn=$'\e[33m'; c_err=$'\e[31m'; c_h=$'\e[1;34m'; c_0=$'\e[0m'
say()  { echo "${c_h}==>${c_0} $*" | tee -a "$LOG"; }
ok()   { echo "  ${c_ok}[ok]${c_0}   $*" | tee -a "$LOG"; }
warn() { echo "  ${c_warn}[warn]${c_0} $*" | tee -a "$LOG"; }
die()  { echo "  ${c_err}[fail]${c_0} $*" | tee -a "$LOG"; exit 1; }
want() { [[ ",$LABS," == *",$1,"* ]]; }
done_or_wanted() { want "$1" || [[ -f "$STATE/lab$1.done" ]]; }
mark_done() { mkdir -p "$STATE"; date > "$STATE/lab$1.done"; }
pkg_avail() { apt-cache policy "$1" 2>/dev/null | grep -q 'Candidate: [0-9]'; }
pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }

# Copy a file into this run's backup folder before it is changed.
backup() {
  [[ -e "$1" ]] || return 0
  mkdir -p "$BACKUP_DIR$(dirname "$1")"
  cp -a "$1" "$BACKUP_DIR$1"
}
# Keep the lab-named "conserved original" (named.conf.orig, nginx.conf.bak ...) once.
keep_original() { if [[ -e "$1" && ! -e "$2" ]]; then cp -a "$1" "$2"; ok "kept original as $2"; fi; }

# write_file PATH [MODE] [OWNER:GROUP]  <<EOF ... EOF
# Writes stdin to PATH only if the content differs; backs up the old copy.
write_file() {
  local dest="$1" mode="${2:-644}" owner="${3:-root:root}" tmp
  tmp=$(mktemp)
  cat > "$tmp"
  mkdir -p "$(dirname "$dest")"
  if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
    rm -f "$tmp"; chmod "$mode" "$dest"; chown "$owner" "$dest"
    ok "$dest already correct"
  else
    backup "$dest"
    install -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$tmp" "$dest"
    rm -f "$tmp"
    ok "wrote $dest"
  fi
}

# Install packages without letting their services auto-start (Apache and Nginx
# both want port 80; starting either during install can fail the install).
apt_install_nostart() {
  printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d; chmod 755 /usr/sbin/policy-rc.d
  apt-get install -y -q "$@" >>"$LOG" 2>&1 || { rm -f /usr/sbin/policy-rc.d; return 1; }
  rm -f /usr/sbin/policy-rc.d
}

trap 'rm -f /usr/sbin/policy-rc.d; die "line $LINENO: \"$BASH_COMMAND\" failed - see $LOG"' ERR

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo bash $0"; exit 1; }
grep -qi ubuntu /etc/os-release || die "This script expects Ubuntu Server."
echo "---- $(date) : labs=$LABS check=$CHECK_ONLY user=$STUDENT_USER ----" >> "$LOG"

if [[ "$IFACE" == auto ]]; then
  IFACE=$(ip -o -4 route show default 2>/dev/null | awk '{print $5; exit}')
  [[ -n "$IFACE" ]] || IFACE=$(ip -o link show | awk -F': ' '$2!="lo"{print $2; exit}')
fi
if [[ "$GATEWAY" == auto ]]; then
  GATEWAY=$(ip -o -4 route show default 2>/dev/null | awk '{print $3; exit}')
  [[ -n "$GATEWAY" ]] || GATEWAY="10.0.2.2"
fi
if [[ -z "$STUDENT_NAME" ]]; then
  STUDENT_NAME=$(getent passwd "$STUDENT_USER" | cut -d: -f5 | cut -d, -f1 || true)
  [[ -n "$STUDENT_NAME" ]] || STUDENT_NAME="CET 245 Student"
fi
student_home() { getent passwd "$STUDENT_USER" | cut -d: -f6 || true; }

# PHP version on this release (8.3 on 24.04, newer on later releases).
php_ver() { find /etc/php -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -V | tail -1 || true; }
time_service() {
  local s
  for s in ntpsec ntp chrony; do
    if [[ -e /etc/systemd/system/$s.service || -e /usr/lib/systemd/system/$s.service || -e /lib/systemd/system/$s.service ]]; then
      echo "$s"; return
    fi
  done
}

# ============================== verification =================================
check() {   # check "description" command...
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else warn "NOT OK: $d"; fi
}
web() {     # web URL -> page body, resolving classroom.edu to this server
  curl -sk -L --noproxy '*' --max-time 5 \
    --resolve "$DOMAIN:80:127.0.0.1" --resolve "$DOMAIN:443:127.0.0.1" \
    --resolve "$SITE_FQDN:80:127.0.0.1" --resolve "$SITE_FQDN:443:127.0.0.1" "$1"
}
cron_has() { crontab -u "$1" -l 2>/dev/null | grep -qF -- "$2"; }
verify() {
  say "Verification"
  local ph sh; ph=$(php_ver); sh=$(student_home)
  want 2 && { check "hostname is $SERVER_HOSTNAME" test "$(hostname)" = "$SERVER_HOSTNAME"
              check "ssh service active" bash -c "systemctl is-active --quiet ssh || systemctl is-active --quiet ssh.socket"; }
  want 3 && { check "$IFACE has $SERVER_IP/$PREFIX" bash -c "ip -4 addr show $IFACE | grep -q '$SERVER_IP/$PREFIX'"
              check "internet reachable (ping 8.8.8.8)" ping -c 2 -W 2 8.8.8.8
              done_or_wanted 6 || check "ufw disabled (Lab 3; Lab 6 turns it back on)" bash -c "! systemctl is-active --quiet ufw"
              check "nftables active" systemctl is-active --quiet nftables
              check "nftables has the trusted set" bash -c "nft list ruleset | grep -q 'set trusted'"
              check "fail2ban installed" dpkg -s fail2ban; }
  want 4 && { check "users instructor and lecturer exist" bash -c "id instructor && id lecturer"
              check "both are in faculty" bash -c "id -nG instructor | grep -qw faculty && id -nG lecturer | grep -qw faculty"
              check "Labs is lecturer:faculty 740" test "$(stat -c '%U:%G %a' /home/lecturer/Labs 2>/dev/null)" = "lecturer:faculty 740"
              check "ACL gives instructor read" bash -c "getfacl -p /home/lecturer/Labs | grep -q '^user:instructor:r--'"
              check "faculty has sudo" bash -c "sudo -l -U lecturer | grep -q '(ALL : ALL) ALL'"; }
  want 5 && { check "named-checkconf passes" named-checkconf
              check "forward zone loads" named-checkzone "$DOMAIN" "/etc/bind/$DOMAIN.zone"
              check "reverse zone loads" named-checkzone "$REVERSE_ZONE" "/etc/bind/$REVERSE_ZONE.zone"
              check "named service active" systemctl is-active --quiet named
              check "dig server.$DOMAIN -> $SERVER_IP" bash -c "dig +short @127.0.0.1 server.$DOMAIN | grep -qx '$SERVER_IP'"
              check "dig -x $SERVER_IP -> server.$DOMAIN." bash -c "dig +short @127.0.0.1 -x $SERVER_IP | grep -qx 'server.$DOMAIN.'"
              check "recursion works (dig ubuntu.com)" bash -c "dig +short @127.0.0.1 ubuntu.com | grep -q ."; }
  want 6 && { check "sshd config valid (sshd -t)" sshd -t
              check "sshd: PasswordAuthentication yes" bash -c "sshd -T 2>/dev/null | grep -qx 'passwordauthentication yes'"
              check "sshd: PermitRootLogin no" bash -c "sshd -T 2>/dev/null | grep -qx 'permitrootlogin no'"
              check "sshd: StrictModes yes" bash -c "sshd -T 2>/dev/null | grep -qx 'strictmodes yes'"
              check "sshd: PubkeyAuthentication yes" bash -c "sshd -T 2>/dev/null | grep -qx 'pubkeyauthentication yes'"
              check "ufw active and allowing SSH" bash -c "ufw status | grep -q 'Status: active' && ufw status | grep -qE '^(OpenSSH|22)'"
              check "user $STUDENT_USER exists" id "$STUDENT_USER"
              check "$STUDENT_USER ~/.ssh/config has Host server" grep -q '^Host server' "$sh/.ssh/config"
              check "$STUDENT_USER ~/for-transfer.txt exists" test -s "$sh/for-transfer.txt"
              check "client key installed (~/.ssh/authorized_keys) - run the client script" test -s "$sh/.ssh/authorized_keys"; }
  want 7 && { check "time service ($(time_service)) active" systemctl is-active --quiet "$(time_service)"
              check "clock synchronized (can take a few minutes after install)" bash -c "ntpq -pn 2>/dev/null | grep -q '^\*' || timedatectl show -p NTPSynchronized --value | grep -qx yes"
              check "atd active" systemctl is-active --quiet atd
              check "root crontab: MAILTO=$STUDENT_USER" cron_has root "MAILTO=$STUDENT_USER"
              check "root crontab: monthly update 0 4 1 * *" cron_has root "0 4 1 * *"
              check "root crontab: log cleanup 0 1 * * *" cron_has root "0 1 * * * find /var/log "
              check "root crontab: Friday disk report" cron_has root "Weekly Disk Usage Report"
              check "root crontab: @reboot message" cron_has root "@reboot"
              check "$STUDENT_USER crontab: Sunday backup" cron_has "$STUDENT_USER" "/backups/home_backup/"
              check "/backups/home_backup owned by $STUDENT_USER" test "$(stat -c %U /backups/home_backup 2>/dev/null)" = "$STUDENT_USER"
              check "/root/rules.good is a valid ruleset" nft -c -f /root/rules.good; }
  want 8 && { check "$WEB_USER exists; $STUDENT_USER in $WEB_USER" bash -c "id $WEB_USER && id -nG $STUDENT_USER | grep -qw $WEB_USER"
              check "/srv/www is $WEB_USER:$WEB_USER" test "$(stat -c %U:%G /srv/www 2>/dev/null)" = "$WEB_USER:$WEB_USER"
              check "$WEB_USER in www-data" bash -c "id -nG $WEB_USER | grep -qw www-data"
              check "apache2 stopped and disabled" bash -c "! systemctl is-active --quiet apache2 && ! systemctl is-enabled --quiet apache2"
              check "nginx -t passes" nginx -t
              check "nginx active" systemctl is-active --quiet nginx
              check "classroom.conf in sites-available" test -f /etc/nginx/sites-available/classroom.conf
              check "/srv/www/website/index.html is 644" test "$(stat -c %a /srv/www/website/index.html 2>/dev/null)" = 644; }
  want 9 && { check "php$ph-fpm active" systemctl is-active --quiet "php$ph-fpm"
              check "php-fpm$ph -t passes" "php-fpm$ph" -t
              check "$SITE_USER has nologin shell" bash -c "getent passwd $SITE_USER | grep -q nologin"
              check "$SITE_DIR has htdocs and tmp" test -d "$SITE_DIR/htdocs" -a -d "$SITE_DIR/tmp"
              check "ACL: $SITE_USER rwx on tmp" bash -c "getfacl -p $SITE_DIR/tmp | grep -q '^user:$SITE_USER:rwx'"
              check "000-server.conf enabled" test -L /etc/nginx/sites-enabled/000-server.conf
              check "site serves index.html" bash -c "curl -sk -L --noproxy '*' --max-time 5 --resolve $DOMAIN:80:127.0.0.1 --resolve $DOMAIN:443:127.0.0.1 http://$DOMAIN/ | grep -qi '<h1'"
              check "PHP runs (info.php shows PHP Version)" bash -c "curl -sk -L --noproxy '*' --max-time 5 --resolve $DOMAIN:80:127.0.0.1 --resolve $DOMAIN:443:127.0.0.1 http://$DOMAIN/info.php | grep -q 'PHP Version'"; }
  want 10 && { check "certificate and key exist" test -s "$TLS_CRT" -a -s "$TLS_KEY"
               check "certificate CN=$DOMAIN, valid 1+ day" bash -c "openssl x509 -in $TLS_CRT -noout -subject | grep -q 'CN *= *$DOMAIN' && openssl x509 -in $TLS_CRT -noout -checkend 86400"
               check "nginx listening on 443" bash -c "ss -ltn | grep -q ':443 '"
               check "HTTP redirects to HTTPS (301)" bash -c "curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 5 --resolve $DOMAIN:80:127.0.0.1 http://$DOMAIN/ | grep -qx 301"
               check "HTTPS serves the site" bash -c "curl -sk --noproxy '*' --max-time 5 --resolve $DOMAIN:443:127.0.0.1 https://$DOMAIN/ | grep -qi '<h1'"; }
  local marks; marks=$(find "$STATE" -name 'lab*.done' -printf '%f\n' 2>/dev/null | sed 's/lab\([0-9]*\).done/\1/' | sort -n | tr '\n' ' ' || true)
  say "Labs this script has completed on this VM: ${marks:-none}"
  say "Log: $LOG"
}
if [[ $CHECK_ONLY -eq 1 ]]; then verify; exit 0; fi

say "Using interface $IFACE, gateway $GATEWAY, labs $LABS, lab user $STUDENT_USER"
say "Backups of changed files go to $BACKUP_DIR"

# ===================== packages first, while DHCP still works ================
say "Installing packages (done first, before any IP address change)"
PKGS=(openssh-server ssh acl curl)
want 3 && PKGS+=(nftables fail2ban)
want 5 && PKGS+=(bind9 bind9-utils dnsutils)
want 6 && PKGS+=(ufw)
if want 7; then
  PKGS+=(cron at)
  if pkg_installed chrony || pkg_installed ntpsec || pkg_installed ntp; then :
  elif pkg_avail ntpsec; then PKGS+=(ntpsec)
  else PKGS+=(ntp); fi
fi
want 9 && PKGS+=(php-fpm php-pear)
want 10 && PKGS+=(openssl ssl-cert)
export DEBIAN_FRONTEND=noninteractive
apt-get update -q >>"$LOG" 2>&1
apt-get install -y -q "${PKGS[@]}" >>"$LOG" 2>&1
ok "installed: ${PKGS[*]}"
if want 7; then
  # mail command for the Lab 7 reports. Skip it if it would pull in an MTA:
  # Postfix is installed and configured properly in Lab 12.
  if command -v mail >/dev/null; then ok "mail command present"
  elif apt-get -s install --no-install-recommends mailutils 2>/dev/null | grep -qE '^Inst (postfix|exim4|sendmail)'; then
    warn "mailutils would install a mail server early - skipped; the cron jobs are still correct and will mail once Lab 12 is done"
  else apt-get install -y -q --no-install-recommends mailutils >>"$LOG" 2>&1 && ok "installed: mailutils"; fi
fi
if want 8; then
  WEBPKGS=(apache2 apache2-utils lynx)
  if pkg_avail nginx-full && apt-cache show nginx-full 2>/dev/null | grep -q '^Depends:.*nginx'; then WEBPKGS+=(nginx-full); else WEBPKGS+=(nginx); fi
  apt_install_nostart "${WEBPKGS[@]}"
  ok "installed (services not auto-started): ${WEBPKGS[*]}"
fi

# ================================ LAB 2 ======================================
if want 2; then
  say "Lab 2 - hostname, root password, SSH"
  if [[ "$(hostname)" != "$SERVER_HOSTNAME" ]]; then
    hostnamectl set-hostname "$SERVER_HOSTNAME"; ok "hostname set to $SERVER_HOSTNAME"
  else ok "hostname already $SERVER_HOSTNAME"; fi
  grep -q "$SERVER_HOSTNAME.$DOMAIN" /etc/hosts || {
    backup /etc/hosts
    sed -i "/^127\.0\.1\.1/d" /etc/hosts
    echo "127.0.1.1 $SERVER_HOSTNAME.$DOMAIN $SERVER_HOSTNAME" >> /etc/hosts
    ok "/etc/hosts: 127.0.1.1 $SERVER_HOSTNAME.$DOMAIN"; }
  echo "root:$LAB_PASSWORD" | chpasswd && ok "root password set (Lab 2 step 3)"
  systemctl enable --now ssh >>"$LOG" 2>&1 && ok "ssh enabled and running"
  mark_done 2
fi

# ================================ LAB 3 ======================================
if want 3; then
  say "Lab 3 - nftables firewall and fail2ban"
  # Firewall first, so the IP change happens with the final ruleset in place.
  if done_or_wanted 6; then
    ok "ufw left alone - Lab 6 turns it on"
  else
    systemctl disable --now ufw >>"$LOG" 2>&1 || true
    ok "ufw disabled"
  fi
  write_file /etc/nftables.conf 755 <<EOF
#!/usr/sbin/nft -f
# CET 245 Lab 3 - inet filter (written by cet245_server_setup.sh)
flush ruleset

table inet filter {
	set trusted {
		type ipv4_addr
		flags interval
		elements = { $NETWORK_CIDR } # Allow addresses in this network
	}

	chain input {
		type filter hook input priority filter; policy drop;
		ct state established,related accept # Replies to traffic we started (apt, ping)
		ct state invalid drop
		ip saddr @trusted accept # Allow trusted IPs
		iif "lo" accept # Allow loopback traffic
		udp dport 53 accept # Allow DNS UDP
		tcp dport 53 accept # Allow DNS TCP
		tcp dport 22 accept # Allow SSH TCP
	}

	chain forward {
		type filter hook forward priority filter; policy drop;
	}

	chain output {
		type filter hook output priority filter; policy accept;
	}
}
EOF
  nft -c -f /etc/nftables.conf || die "nftables.conf has a syntax error"
  ok "nftables.conf syntax OK"
  systemctl enable nftables >>"$LOG" 2>&1
  systemctl restart nftables && ok "nftables enabled and ruleset loaded"
  # "flush ruleset" also clears UFW's tables; put them back if UFW is on.
  if systemctl is-active --quiet ufw; then ufw reload >>"$LOG" 2>&1 && ok "ufw rules reloaded on top of nftables"; fi
  systemctl enable --now fail2ban >>"$LOG" 2>&1 && ok "fail2ban installed and running (defaults; jail.conf untouched)"

  say "Lab 3 - static IP $SERVER_IP/$PREFIX on $IFACE"
  NP=/etc/netplan/50-cloud-init.yaml
  for f in /etc/netplan/*.yaml; do backup "$f"; done
  # Stop cloud-init from rewriting the netplan file on the next boot.
  mkdir -p /etc/cloud/cloud.cfg.d
  echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
  # Remove other netplan files so only ours configures this interface.
  for f in /etc/netplan/*.yaml; do
    if [[ -e "$f" && "$f" != "$NP" ]]; then mv "$f" "$f.disabled"; ok "moved aside $f"; fi
  done
  ns=$(printf '%s, ' "${UPSTREAM_DNS[@]}"); ns="${ns%, }"
  write_file "$NP" 600 <<EOF
# CET 245 Lab 3 - static address (written by cet245_server_setup.sh)
network:
  version: 2
  ethernets:
    $IFACE:
      dhcp4: false
      addresses:
        - $SERVER_IP/$PREFIX
      routes:
        - to: default
          via: $GATEWAY
      nameservers:
        addresses: [$ns]
        search: []
EOF
  netplan generate || die "netplan rejected $NP - the old files are in $BACKUP_DIR/etc/netplan"
  ok "netplan file valid"
  netplan apply
  sleep 3
  ip -4 addr show "$IFACE" | grep -q "$SERVER_IP/$PREFIX" && ok "$IFACE now has $SERVER_IP/$PREFIX" || warn "address not applied yet - check: ip addr"
  ping -c 2 -W 2 8.8.8.8 >/dev/null 2>&1 && ok "internet reachable through $GATEWAY" \
    || warn "cannot reach 8.8.8.8 via $GATEWAY - see the Gateway note in the guide"
  mark_done 3
fi

# ================================ LAB 4 ======================================
if want 4; then
  say "Lab 4 - users, groups, permissions, ACLs, sudo"
  id instructor &>/dev/null || { useradd instructor; ok "user instructor created (no home dir, as in the lab)"; }
  echo "instructor:$LAB_PASSWORD" | chpasswd
  getent group faculty >/dev/null || { groupadd faculty; ok "group faculty created"; }
  usermod -aG faculty instructor
  id lecturer &>/dev/null || { useradd --shell /bin/bash --create-home --user-group --groups faculty lecturer; ok "user lecturer created"; }
  usermod -aG faculty lecturer
  echo "lecturer:$LAB_PASSWORD" | chpasswd
  ok "passwords set; both users in faculty"
  mkdir -p /home/lecturer/Labs
  chown lecturer:faculty /home/lecturer/Labs
  chmod 740 /home/lecturer/Labs
  setfacl -m u:instructor:r /home/lecturer/Labs
  ok "/home/lecturer/Labs: lecturer:faculty, 740, ACL u:instructor:r"
  # The lab edits /etc/sudoers with visudo; a drop-in file does the same thing
  # without touching the main file, and visudo -c validates it first.
  SUD=/etc/sudoers.d/cet245-faculty
  echo '%faculty ALL=(ALL:ALL) ALL' > "$SUD.tmp"
  visudo -cf "$SUD.tmp" >/dev/null && { chmod 440 "$SUD.tmp"; mv "$SUD.tmp" "$SUD"; ok "sudo rule: %faculty ALL=(ALL:ALL) ALL ($SUD)"; } \
    || { rm -f "$SUD.tmp"; die "sudoers rule failed validation"; }
  mark_done 4
fi

# ================================ LAB 5 ======================================
if want 5; then
  say "Lab 5 - BIND9 for $DOMAIN"
  cd /etc/bind
  [[ -s /etc/bind/rndc.key ]] || { rndc-confgen -a >>"$LOG" 2>&1; ok "rndc.key generated"; }
  keep_original /etc/bind/named.conf /etc/bind/named.conf.orig
  mkdir -p /var/log/named
  chmod 770 /var/log/named
  chgrp bind /var/log/named
  ok "/var/log/named created (770, group bind)"
  fwd=$(printf '\t\t%s;\n' "${UPSTREAM_DNS[@]:0:2}")
  write_file /etc/bind/named.conf 644 root:bind <<EOF
// CET 245 Lab 5 - named.conf, Debian version of the textbook example
// (written by cet245_server_setup.sh; original kept as named.conf.orig)

// IP address lists. (The "secondaries" acl is removed, as in Lab 5 step 3.)
acl "loopback" {
	127.0.0.0/8;
	::1/128;
};

options {
	directory "/var/cache/bind";
	pid-file "/run/named/named.pid";

	listen-on {
		127.0.0.1;
		$SERVER_IP;
	};

	allow-query { localnets; };
	allow-query-cache { localnets; };
	allow-recursion { localnets; };
	allow-transfer { none; };
	allow-update { none; };

	// Cloudflare/APNIC DNS cache.
	forwarders {
$fwd
	};
};

logging {
	channel default_log {
		file "/var/log/named/named.log" versions 5 size 50M;
		print-time yes;
		print-severity yes;
		print-category yes;
	};
	category default { default_log; };
	category general { default_log; };
};

// Dynamic updates and reloads.
include "/etc/bind/rndc.key";
controls {
	inet 127.0.0.1 port 953 allow { 127.0.0.1; } keys { rndc-key; };
};

// Root hints.
zone "." IN {
	type hint;
	file "/usr/share/dns/root.hints";
};

// localhost.
zone "localhost" IN {
	type master;
	notify no;
	file "/etc/bind/db.local";
};

// Lab 5 step 6 - forward zone.
zone "$DOMAIN" IN {
	type master;
	file "/etc/bind/$DOMAIN.zone";
};

// Lab 5 step 9 - reverse zone.
zone "$REVERSE_ZONE" IN {
	type master;
	file "/etc/bind/$REVERSE_ZONE.zone";
};
EOF
  SERIAL="$(date +%Y%m%d)01"
  LAST_OCTET="${SERVER_IP##*.}"
  write_file "/etc/bind/$DOMAIN.zone" 644 root:bind <<EOF
; CET 245 Lab 5 - forward zone for $DOMAIN
\$ORIGIN $DOMAIN.
\$TTL 1d
@		IN	SOA	ns.$DOMAIN. sysadmin.$DOMAIN. (
					$SERIAL	; Serial (YYYYMMDDnn)
					3h		; Refresh
					1h		; Retry
					1000h		; Expire
					1d		; TTL
				)
@		IN	NS	ns
@		IN	MX	10 mx.$DOMAIN.
@		IN	A	$SERVER_IP
server		IN	A	$SERVER_IP
ns		IN	A	$SERVER_IP
mx		IN	A	$SERVER_IP
EOF
  write_file "/etc/bind/$REVERSE_ZONE.zone" 644 root:bind <<EOF
; CET 245 Lab 5 - reverse zone for $NETWORK_CIDR (NS and PTR only)
\$ORIGIN $REVERSE_ZONE.
\$TTL 2d
@	IN	SOA	ns.$DOMAIN. sysadmin.$DOMAIN. (
				$SERIAL	; Serial
				24h		; Refresh
				2h		; Retry
				1000h		; Expire
				2d		; TTL
			)
@	IN	NS	ns.$DOMAIN.
$LAST_OCTET	IN	PTR	server.$DOMAIN.
EOF
  named-checkconf || die "named-checkconf failed"
  ok "named-checkconf passed"
  named-checkzone "$DOMAIN" "/etc/bind/$DOMAIN.zone" >>"$LOG" || die "forward zone failed named-checkzone"
  ok "forward zone OK (serial $SERIAL)"
  named-checkzone "$REVERSE_ZONE" "/etc/bind/$REVERSE_ZONE.zone" >>"$LOG" || die "reverse zone failed named-checkzone"
  ok "reverse zone OK"
  systemctl enable named >>"$LOG" 2>&1 || true
  systemctl restart named && ok "BIND (named) restarted"

  say "Lab 5 step 10 - point systemd-resolved at the local BIND"
  backup /etc/systemd/resolved.conf
  sed -i -E 's/^#?DNS=.*/DNS=127.0.0.1/; s/^#?FallbackDNS=.*/FallbackDNS=1.1.1.1 8.8.8.8/' /etc/systemd/resolved.conf
  grep -q '^DNS=127.0.0.1' /etc/systemd/resolved.conf || echo 'DNS=127.0.0.1' >> /etc/systemd/resolved.conf
  systemctl restart systemd-resolved
  resolvectl flush-caches 2>/dev/null || true
  ok "resolved.conf: DNS=127.0.0.1"
  mark_done 5
fi

# ================================ LAB 6 ======================================
# set_sshd KEY VALUE : set one sshd_config option. Replaces the first line for
# KEY (commented or not), comments out later active duplicates, and if KEY is
# missing adds it before any Match block. Lines inside Match blocks are left alone.
set_sshd() {
  local k="$1" v="$2" f=/etc/ssh/sshd_config tmp
  tmp=$(mktemp)
  awk -v k="$k" -v v="$v" '
    BEGIN { lk = tolower(k); done = 0; inmatch = 0 }
    {
      line = tolower($0)
      if (line ~ /^[ \t]*match[ \t]/) {            # global options end here
        if (!done) { print k " " v; done = 1 }
        inmatch = 1
      }
      if (!inmatch && match(line, "^[ \t]*#?[ \t]*" lk "[ \t]")) {
        if (!done) { print k " " v; done = 1; next }
        if (line !~ /^[ \t]*#/) { print "#" $0; next }
      }
      print
    }
    END { if (!done) print k " " v }' "$f" > "$tmp"
  cat "$tmp" > "$f"; rm -f "$tmp"
}
if want 6; then
  say "Lab 6 - SSH server options and UFW"
  if ! id "$STUDENT_USER" &>/dev/null; then
    useradd --create-home --shell /bin/bash "$STUDENT_USER"
    echo "$STUDENT_USER:$LAB_PASSWORD" | chpasswd
    warn "user $STUDENT_USER did not exist - created it with the lab password"
  fi
  SH=$(student_home)
  backup /etc/ssh/sshd_config
  set_sshd PasswordAuthentication yes   # step 1
  set_sshd PermitRootLogin no           # step 3
  set_sshd StrictModes yes
  set_sshd PubkeyAuthentication yes
  # Files in sshd_config.d are read first and win; comment out any that
  # override these four (cloud-init often sets PasswordAuthentication no).
  for f in /etc/ssh/sshd_config.d/*.conf; do
    [[ -e "$f" ]] || continue
    if grep -qiE '^[[:space:]]*(PasswordAuthentication|PermitRootLogin|StrictModes|PubkeyAuthentication)[[:space:]]' "$f"; then
      backup "$f"
      sed -i -E 's/^([[:space:]]*)(PasswordAuthentication|PermitRootLogin|StrictModes|PubkeyAuthentication)([[:space:]])/#\1\2\3/I' "$f"
      ok "commented overriding options in $f"
    fi
  done
  sshd -t || die "sshd_config failed sshd -t - the old copy is in $BACKUP_DIR/etc/ssh"
  ok "sshd_config: PasswordAuthentication yes, PermitRootLogin no, StrictModes yes, PubkeyAuthentication yes"
  systemctl restart ssh >>"$LOG" 2>&1 || systemctl restart ssh.socket >>"$LOG" 2>&1 || true
  ok "ssh restarted (open sessions stay connected)"

  # UFW and the Lab 3 nftables rules both filter traffic: a packet must pass
  # both. So besides SSH (the lab step), UFW also allows the trusted lab
  # network, just like the Lab 3 "trusted" set; otherwise DNS from the client
  # and the web labs (8-10) would be blocked.
  ufw allow OpenSSH >>"$LOG" 2>&1 || ufw allow 22/tcp >>"$LOG" 2>&1
  ufw allow from "$NETWORK_CIDR" >>"$LOG" 2>&1
  ufw allow 53 >>"$LOG" 2>&1
  mkdir -p /etc/systemd/system/ufw.service.d
  write_file /etc/systemd/system/ufw.service.d/cet245.conf <<EOF
# CET 245: load UFW after nftables, whose "flush ruleset" would clear UFW's rules.
[Unit]
After=nftables.service
EOF
  systemctl daemon-reload
  ufw --force enable >>"$LOG" 2>&1
  systemctl enable ufw >>"$LOG" 2>&1 || true
  ok "ufw enabled: OpenSSH, $NETWORK_CIDR, DNS 53"

  say "Lab 6 - $STUDENT_USER's SSH client config and transfer file"
  install -d -m 700 -o "$STUDENT_USER" -g "$STUDENT_USER" "$SH/.ssh"
  if ! grep -q '^Host server' "$SH/.ssh/config" 2>/dev/null; then
    printf 'Host server\n    HostName server.%s\n    User %s\n' "$DOMAIN" "$STUDENT_USER" >> "$SH/.ssh/config"
    ok "added Host server to $SH/.ssh/config (step 6)"
  else ok "$SH/.ssh/config already has Host server"; fi
  chown "$STUDENT_USER:$STUDENT_USER" "$SH/.ssh/config"; chmod 600 "$SH/.ssh/config"
  FT="$SH/for-transfer.txt"
  if [[ ! -s "$FT" ]]; then
    printf '%s\n%s\nThis is a file for sending via SFTP\n' "$STUDENT_NAME" "$(date +%F)" > "$FT"
    ok "created $FT (step 7)"
  fi
  grep -q 'SCP' "$FT" || { echo "This file is also for sending via SCP." >> "$FT"; ok "added the SCP line (step 8)"; }
  chown "$STUDENT_USER:$STUDENT_USER" "$FT"
  [[ -s "$SH/.ssh/authorized_keys" ]] && ok "authorized_keys present" \
    || warn "no client key yet - the client script creates key-student-server and copies it here (steps 9-10)"
  mark_done 6
fi

# ================================ LAB 7 ======================================
# cron_block USER RE-OF-OLD-LINES  <<EOF ... EOF
# Replaces this script's block in USER's crontab and drops older hand-typed
# copies of the same jobs (matched by the regex), so broken versions such as
# /var/logs or a missing upgrade are replaced instead of duplicated.
cron_block() {
  local user="$1" old_re="$2" block cur new
  block=$(cat)
  cur=$(crontab -u "$user" -l 2>/dev/null || true)
  new=$(printf '%s\n' "$cur" | awk '/^# >>> CET245/{skip=1} !skip{print} /^# <<< CET245/{skip=0}' \
        | grep -vE "$old_re" || true)
  new=$(printf '%s\n%s\n' "$new" "$block" | sed '/./,$!d')
  if [[ "$new" == "$cur" ]]; then ok "$user crontab already correct"; return; fi
  mkdir -p "$BACKUP_DIR"; printf '%s\n' "$cur" > "$BACKUP_DIR/crontab.$user"
  printf '%s\n' "$new" | crontab -u "$user" -
  ok "$user crontab updated (old copy: $BACKUP_DIR/crontab.$user)"
}
if want 7; then
  say "Lab 7 - time sync and at"
  TS=$(time_service)
  [[ -n "$TS" ]] || die "no ntp/ntpsec/chrony service found after install"
  systemctl enable --now "$TS" >>"$LOG" 2>&1 && ok "$TS enabled and running"
  systemctl enable --now atd >>"$LOG" 2>&1 && ok "atd enabled and running"
  if ntpq -pn 2>/dev/null | grep -q '^\*'; then ok "clock synchronized (ntpq shows a * peer)"
  else warn "clock not synchronized yet - normal right after install; check later with: ntpq -pn"; fi

  say "Lab 7 - cron jobs"
  id "$STUDENT_USER" &>/dev/null || die "user $STUDENT_USER missing - run Lab 6 or use --user"
  cron_block root '^[[:space:]]*(MAILTO|PATH|Path)=|^[^#]*0 4 1 \* \*|^[^#]*find /var/logs?[ /]|Weekly (Disk )?Usage R|^[^#]*@reboot.*reboot' <<EOF
# >>> CET245 Lab 7 (managed by cet245_server_setup.sh) >>>
# Step 2 - mail all output to $STUDENT_USER; search the three default directories
MAILTO=$STUDENT_USER
PATH=/bin:/usr/bin:/usr/local/bin
# Step 3 - system update on the 1st of every month at 4:00 AM
#          (apt also needs the sbin directories, so this job widens PATH)
0 4 1 * * export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; apt-get -q update && DEBIAN_FRONTEND=noninteractive apt-get -y -q upgrade
# Step 4 - delete log files older than 30 days, daily at 1:00 AM
0 1 * * * find /var/log -type f -name '*.log' -mtime +30 -delete
# Step 5 - disk usage report to admin, Fridays at 8:00 AM
0 8 * * 5 df -h | mail -s "Weekly Disk Usage Report" $ADMIN_MAIL
# Step 8 - tell admin when the server restarts
@reboot echo "The server just rebooted." | mail -s "Reboot Notification" $ADMIN_MAIL
# <<< CET245 Lab 7 <<<
EOF
  install -d -m 755 /backups
  install -d -m 750 -o "$STUDENT_USER" -g "$STUDENT_USER" /backups/home_backup
  ok "/backups/home_backup owned by $STUDENT_USER"
  cron_block "$STUDENT_USER" '^[^#]*tar .*home_back' <<EOF
# >>> CET245 Lab 7 (managed by cet245_server_setup.sh) >>>
# Step 6 - back up the home directory every Sunday at midnight (dated tarball)
0 0 * * 0 tar -czf /backups/home_backup/home_\$(date +\%F).tar.gz -C /home $STUDENT_USER
# <<< CET245 Lab 7 <<<
EOF
  # Step 9's "known-good firewall rules file" for: echo "nft -f /root/rules.good" | at now + 5 minutes
  if [[ -s /etc/nftables.conf ]] && nft -c -f /etc/nftables.conf >/dev/null 2>&1; then
    cp /etc/nftables.conf /root/rules.good
  else
    { echo "flush ruleset"; nft list ruleset; } > /root/rules.good
  fi
  chmod 600 /root/rules.good
  ok "/root/rules.good saved (the step 9 at job itself is one-time, so it is not queued)"
  mark_done 7
fi

# ================================ LAB 8 ======================================
# nginx_test: run nginx -t. If it fails, set aside any site in sites-enabled
# that this script does not manage (a student's leftover or broken file), then
# test again; the set-aside links are kept in the backup folder.
NGINX_SITES="classroom.conf 000-server.conf"
nginx_test() {
  if nginx -t >>"$LOG" 2>&1; then ok "nginx -t passed"; return; fi
  local f n moved=0
  for f in /etc/nginx/sites-enabled/*; do
    [[ -e "$f" || -L "$f" ]] || continue
    n=$(basename "$f")
    [[ " $NGINX_SITES " == *" $n "* ]] && continue
    mkdir -p "$BACKUP_DIR/sites-enabled-set-aside"
    mv "$f" "$BACKUP_DIR/sites-enabled-set-aside/"
    warn "set aside sites-enabled/$n (not part of the labs' final setup)"
    moved=1
  done
  if [[ $moved -eq 1 ]] && nginx -t >>"$LOG" 2>&1; then ok "nginx -t passed"; return; fi
  nginx -t || true
  die "nginx -t failed - old files are in $BACKUP_DIR/etc/nginx"
}
if want 8; then
  say "Lab 8 - web directories and the $WEB_USER user"
  id "$STUDENT_USER" &>/dev/null || die "user $STUDENT_USER missing - run Lab 6 or use --user"
  install -d /srv/www/website
  id "$WEB_USER" &>/dev/null || { useradd --user-group --create-home --shell /bin/bash "$WEB_USER"; ok "user $WEB_USER created"; }
  usermod -aG "$WEB_USER" "$STUDENT_USER"
  chown "$WEB_USER:$WEB_USER" /srv/www /srv/www/website
  chmod 0771 /srv/www/website
  if done_or_wanted 9; then chmod 0775 /srv/www; else chmod 0771 /srv/www; fi   # Lab 9 step 8 adds o+r
  ok "/srv/www and /srv/www/website: $WEB_USER:$WEB_USER; $STUDENT_USER in $WEB_USER"

  say "Lab 8 - Apache configuration (then stopped, as in step 6)"
  A=/etc/apache2/apache2.conf
  backup "$A"
  if grep -q '^ServerAdmin' "$A"; then sed -i "s/^ServerAdmin.*/ServerAdmin $WEB_USER@$DOMAIN/" "$A"
  else printf '\n# CET 245 Lab 8 step 3\nServerAdmin %s@%s\n' "$WEB_USER" "$DOMAIN" >> "$A"; fi
  sed -i -E '/^#<Directory \/srv\/>/,/^#<\/Directory>/ s/^#//' "$A"
  sed -i -E 's#^<Directory /srv/>#<Directory /srv/www/>#' "$A"
  ok "apache2.conf: ServerAdmin $WEB_USER@$DOMAIN; <Directory /srv/www/> enabled"
  # Step 4 (pages 193-194): drop cgi-bin and the default site, set modules.
  a2disconf -q serve-cgi-bin >>"$LOG" 2>&1 || true
  a2dissite -q 000-default >>"$LOG" 2>&1 || true
  a2dismod -q -f mpm_prefork mpm_worker >>"$LOG" 2>&1 || true
  a2enmod -q mpm_event proxy proxy_fcgi rewrite socache_shmcb ssl >>"$LOG" 2>&1 || warn "a2enmod reported a problem - see $LOG"
  ok "cgi-bin and 000-default removed; mpm_event proxy proxy_fcgi rewrite socache_shmcb ssl on; prefork/worker off"
  apache2ctl -t >>"$LOG" 2>&1 && ok "apache2ctl -t passed" || warn "apache2ctl -t reported a problem - see $LOG"
  systemctl disable --now apache2 >>"$LOG" 2>&1 || true
  ok "apache2 stopped and disabled (step 6)"

  say "Lab 8 - Nginx"
  keep_original /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak
  write_file /etc/nginx/nginx.conf <<'EOF'
# CET 245 Lab 8 - nginx.conf (page 199; written by cet245_server_setup.sh)
# The original is kept as nginx.conf.bak.
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;   # Debian's dynamic modules

events {
	worker_connections 1024;
}

http {
	include /etc/nginx/mime.types;   # so browsers render pages instead of downloading them
	default_type application/octet-stream;
	sendfile on;
	index index.html index.php index.htm;

	access_log /var/log/nginx/access.log;
	error_log /var/log/nginx/error.log;

	# The hosted websites.
	include /etc/nginx/sites-enabled/*.conf;
}
EOF
  rm -f /etc/nginx/sites-enabled/default
  write_file /etc/nginx/sites-available/classroom.conf <<EOF
# CET 245 Lab 8 step 9 - classroom.edu (written by cet245_server_setup.sh)
server {
	listen 80;
	server_name $DOMAIN;

	root /srv/www/website;
	index index.html;

	location / {
		try_files \$uri \$uri/ =404;
	}

	error_page 404 /404.html;
	error_page 500 502 503 504 /50x.html;
	location = /50x.html {
		root /srv/www/website;
	}
}
EOF
  usermod -aG www-data "$WEB_USER" && ok "$WEB_USER added to www-data (step 10)"
  if done_or_wanted 9; then
    ok "classroom.conf left disabled - Lab 9 replaces it with 000-server.conf"
  else
    ln -sfn ../sites-available/classroom.conf /etc/nginx/sites-enabled/classroom.conf
    ok "sites-enabled/classroom.conf -> ../sites-available/classroom.conf"
  fi
  W=/srv/www/website
  if [[ ! -s "$W/index.html" ]]; then
    cat > "$W/index.html" <<EOF
<!DOCTYPE html>
<html>
<head>
	<title>Web Server Configuration with Nginx</title>
</head>
<body>
	<h1>Web Server Configuration with Nginx</h1>
	<p>$STUDENT_NAME</p>
</body>
</html>
EOF
    ok "created $W/index.html (step 11)"
  else ok "$W/index.html exists - left as is"; fi
  [[ -e "$W/404.html" ]] || echo "<h1>404 - Page Not Found</h1>" > "$W/404.html"
  [[ -e "$W/50x.html" ]] || echo "<h1>Server Error</h1>" > "$W/50x.html"
  chown "$WEB_USER:$WEB_USER" "$W"/*.html
  chmod 644 "$W"/*.html
  ok "web pages are 644 (step 12)"
  systemctl enable nginx >>"$LOG" 2>&1
  if want 9; then
    ok "nginx test and restart happen after Lab 9 rewrites the site files"
  else
    nginx_test
    systemctl restart nginx && ok "nginx enabled and restarted"
  fi
  mark_done 8
fi

# ================================ LAB 9 / 10 vhost ===========================
write_vhost() {   # 000-server.conf: port 80 only (Lab 9) or HTTPS (Lab 10)
  local php="	location ~ \\.php\$ {
		root $SITE_DIR/htdocs;   # repeated here, as in Lab 9 step 6
		include snippets/fastcgi-php.conf;
		fastcgi_pass 127.0.0.1:$FPM_PORT;
	}"
  if done_or_wanted 10; then
    write_file /etc/nginx/sites-available/000-server.conf <<EOF
# CET 245 Labs 9-10 - default virtual server (pages 221 and 234-235)
# Written by cet245_server_setup.sh
server {
	# Listen on port 80.
	listen 80;

	# The name for the virtual server.
	server_name $SITE_FQDN $DOMAIN;

	# Redirect all requests to the HTTPS variant.
	return 301 https://\$host\$request_uri;
}

server {
	# Listen on port 443, and enable SSL/TLS.
	listen 443 ssl;

	# The name for the virtual server.
	server_name $SITE_FQDN $DOMAIN;

	# Enable session cache and allow multiple requests per session, to spare CPU.
	ssl_session_cache shared:SSL:5m;
	ssl_session_timeout 10m;
	keepalive_timeout 75s;

	# SSL/TLS certificate and key (Lab 10 step 2).
	ssl_certificate $TLS_CRT;
	ssl_certificate_key $TLS_KEY;

	# Log files.
	access_log /var/log/www-server.log;
	error_log /var/log/www-server.error;

	# Document root and index file (Lab 10 step 6).
	root $SITE_DIR/htdocs;
	index index.html index.php index.htm;
	location / {
		root $SITE_DIR/htdocs;
		index index.html index.php index.htm;
	}

	# Files with a name ending in .php go to the PHP-FPM on port $FPM_PORT.
$php
}
EOF
  else
    write_file /etc/nginx/sites-available/000-server.conf <<EOF
# CET 245 Lab 9 - default virtual server (page 221, Debian version, no http block)
# Written by cet245_server_setup.sh
server {
	# Listen on port 80.
	listen 80;

	# The name for the virtual server.
	server_name $SITE_FQDN $DOMAIN;

	# Log files.
	access_log /var/log/www-server.log;
	error_log /var/log/www-server.error;

	# Document root and index file.
	location / {
		root $SITE_DIR/htdocs;
		index index.html index.php index.htm;
	}

	# Files with a name ending in .php go to the PHP-FPM on port $FPM_PORT.
$php
}
EOF
  fi
}

# ================================ LAB 9 ======================================
if want 9; then
  say "Lab 9 - PHP-FPM pool"
  command -v nginx >/dev/null || die "Nginx is not installed - include Lab 8 (--labs 8,9)"
  id "$WEB_USER" &>/dev/null || die "user $WEB_USER missing - include Lab 8 (--labs 8,9)"
  PHPV=$(php_ver); [[ -n "$PHPV" ]] || die "PHP-FPM is not installed"
  POOL=/etc/php/$PHPV/fpm/pool.d
  ok "PHP version $PHPV ($POOL)"
  # Step 1: keep the Debian sample as www.conf.orig. Step 5 then retires the
  # step 1 www.conf as www.conf.bak, leaving server.conf as the only pool.
  if [[ -f "$POOL/www.conf" ]] && grep -q '^\[www\]' "$POOL/www.conf"; then
    keep_original "$POOL/www.conf" "$POOL/www.conf.orig"
  fi
  # server.conf is the only active pool at the end of Lab 9; any other pool
  # file would fight it for port $FPM_PORT, so retire them all.
  for f in "$POOL"/*.conf; do
    [[ -e "$f" && "$(basename "$f")" != server.conf ]] || continue
    backup "$f"; rm -f "$f"
    ok "retired pool file $(basename "$f") (step 5 leaves only server.conf)"
  done
  write_file "$POOL/www.conf.bak" <<EOF
; CET 245 Lab 9 step 1 - www.conf (pages 206-208), retired in step 5 as www.conf.bak
[$SITE_FQDN]
user = $SITE_USER
group = $SITE_USER
listen = 127.0.0.1:$FPM_PORT
listen.allowed_clients = 127.0.0.1
pm = dynamic
pm.max_children = 20
pm.min_spare_servers = 5
pm.max_spare_servers = 10
EOF

  say "Lab 9 - $SITE_USER and $SITE_DIR"
  if id "$SITE_USER" &>/dev/null; then
    usermod --home "$SITE_DIR" --shell /usr/sbin/nologin "$SITE_USER" >>"$LOG" 2>&1 || true
    ok "$SITE_USER exists (home $SITE_DIR, shell nologin)"
  else
    useradd --comment "$SITE_FQDN" --home-dir "$SITE_DIR" --no-create-home --user-group --shell /usr/sbin/nologin "$SITE_USER"
    ok "$SITE_USER created (no home dir created, login disabled, nologin shell)"
  fi
  install -d "$SITE_DIR"
  for d in alias bin cgi-bin conf htdocs tmp; do install -d "$SITE_DIR/$d"; done
  H="$SITE_DIR/htdocs"
  if [[ ! -s "$H/index.html" ]]; then
    cat > "$H/index.html" <<EOF
<!DOCTYPE html>
<html>
<head>
	<title>Virtual Host Configuration with PHP</title>
</head>
<body>
	<h1>Virtual Host Configuration with PHP</h1>
	<p>$STUDENT_NAME</p>
</body>
</html>
EOF
    ok "created $H/index.html (step 4)"
  else ok "$H/index.html exists - left as is"; fi
  [[ -s "$H/info.php" ]] || { echo '<?php phpinfo(); ?>' > "$H/info.php"; ok "created $H/info.php (step 8)"; }
  # Step 3 (and pages 213-214): ownership and mode, then ACLs for PHP-FPM and Nginx.
  chown -R "$WEB_USER:$WEB_USER" "$SITE_DIR"
  chmod -R 2770 "$SITE_DIR"
  # Access ACLs on everything; default ACLs (inherited by new files) on directories only.
  setfacl -R -m "u:$SITE_USER:rx,u:www-data:rx" "$SITE_DIR"
  find "$SITE_DIR" -type d -exec setfacl -m "d:u:$SITE_USER:rx,d:u:www-data:rx" {} +
  setfacl -R -m "u:$SITE_USER:rwx" "$SITE_DIR/tmp"
  find "$SITE_DIR/tmp" -type d -exec setfacl -m "d:u:$SITE_USER:rwx" {} +
  # Step 8: others need execute down the path and read on htdocs.
  chmod o+x /srv
  chmod o+rx /srv/www "$SITE_DIR"
  chmod -R o+rx "$H"
  ok "$SITE_DIR: $WEB_USER:$WEB_USER 2770, ACL $SITE_USER rx (tmp rwx), www-data rx, o+rx on the path"

  say "Lab 9 - server.conf and 000-server.conf"
  write_file "$POOL/server.conf" <<EOF
; CET 245 Lab 9 step 5 - minimal pool (pages 216-217)
; The name for the pool. Amongst other things, this name is displayed in 'ps' output.
[$SITE_FQDN]

; PHP scripts will be executed under these names.
user = $SITE_USER
group = $SITE_USER

; Only accept requests from the server itself.
listen = 127.0.0.1:$FPM_PORT
listen.allowed_clients = 127.0.0.1

; Process manager options.
pm = ondemand
pm.max_children = 3

; Environment variables.
env[TMP] = $SITE_DIR/tmp
env[TEMP] = $SITE_DIR/tmp
env[TMPDIR] = $SITE_DIR/tmp

; PHP configuration variables.
php_flag[short_open_tag] = off
php_admin_value[open_basedir] = $SITE_DIR:/usr/share
php_admin_value[upload_tmp_dir] = $SITE_DIR/tmp
php_admin_value[session.save_path] = $SITE_DIR/tmp
EOF
  "php-fpm$PHPV" -t >>"$LOG" 2>&1 || { "php-fpm$PHPV" -t; die "php-fpm$PHPV -t failed"; }
  ok "php-fpm$PHPV -t passed"
  systemctl enable "php$PHPV-fpm" >>"$LOG" 2>&1
  systemctl restart "php$PHPV-fpm" && ok "php$PHPV-fpm restarted"
  write_vhost
  if [[ -e /etc/nginx/sites-enabled/classroom.conf ]]; then
    mv -f /etc/nginx/sites-enabled/classroom.conf /etc/nginx/sites-enabled/classroom.conf.bak
    ok "sites-enabled/classroom.conf moved aside (step 7)"
  fi
  ln -sfn ../sites-available/000-server.conf /etc/nginx/sites-enabled/000-server.conf
  ok "sites-enabled/000-server.conf -> ../sites-available/000-server.conf"
  if want 10 || { done_or_wanted 10 && [[ ! -s "$TLS_CRT" ]]; }; then
    ok "nginx test and restart happen in Lab 10, after the certificate"
  else
    nginx_test
    systemctl restart nginx && ok "nginx restarted"
  fi
  mark_done 9
fi

# ================================ LAB 10 =====================================
if want 10; then
  say "Lab 10 - self-signed certificate"
  [[ -f /etc/nginx/sites-available/000-server.conf ]] || die "000-server.conf missing - include Lab 9 (--labs 9,10)"
  if [[ -s "$TLS_CRT" && -s "$TLS_KEY" ]] \
     && openssl x509 -in "$TLS_CRT" -noout -checkend 86400 >/dev/null 2>&1 \
     && openssl x509 -in "$TLS_CRT" -noout -subject | grep -q "CN *= *$DOMAIN" \
     && [[ "$(openssl x509 -in "$TLS_CRT" -noout -pubkey | sha256sum)" == "$(openssl pkey -in "$TLS_KEY" -pubout 2>/dev/null | sha256sum)" ]]; then
    ok "existing $TLS_CRT is valid for $DOMAIN and matches its key - kept"
  else
    backup "$TLS_CRT"; backup "$TLS_KEY"
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout "$TLS_KEY" -out "$TLS_CRT" -subj "$TLS_SUBJ" >>"$LOG" 2>&1
    chmod 600 "$TLS_KEY"; chmod 644 "$TLS_CRT"
    ok "generated $TLS_CRT and $TLS_KEY (365 days, RSA 2048, $TLS_SUBJ)"
  fi
  [[ -e /etc/ssl/certs/ssl-cert-snakeoil.pem ]] && ok "snakeoil certificate present for step 4"
  write_vhost
  nginx_test
  systemctl restart nginx && ok "nginx restarted with HTTPS"
  mark_done 10
fi

verify
first=${LABS%%,*}; last=${LABS##*,}
if [[ "$first" == "$last" ]]; then span="Lab $first"; else span="Labs $first-$last"; fi
say "Done. Take a snapshot now (for example: '$span complete'), then run cet245_client_setup.sh on the client."
