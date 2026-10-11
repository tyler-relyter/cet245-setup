#!/usr/bin/env bash
# =============================================================================
#  CET 245 - Internet Servers  |  Ubuntu Server catch-up / rebuild script
#  Covers Labs 2-5:  base tools + SSH  ->  static IP + nftables + fail2ban
#                    ->  users, groups, ACLs, sudo  ->  DNS with BIND9
#
#  Run ON THE UBUNTU SERVER VM, as root:
#      sudo bash cet245_server_setup.sh                # Labs 2 through 5
#      sudo bash cet245_server_setup.sh --through 4    # stop before BIND
#      sudo bash cet245_server_setup.sh --labs 4,5     # only Labs 4 and 5
#      sudo bash cet245_server_setup.sh --check        # verify only, change nothing
#
#  Run it from the VM's console window, NOT over SSH: Lab 3 changes the
#  server's IP address, which drops any SSH session connected to the old one.
#
#  Lab 1 (VirtualBox, ISOs, NAT Network, VM creation) happens on the host
#  and is covered in the companion guide, not here.
#
#  Safe to re-run: every step checks before it changes anything, and every
#  file it replaces is copied to <file>.orig first (only the first time).
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
# -----------------------------------------------------------------------------

LOG=/var/log/cet245-setup.log
LABS="2,3,4,5"
CHECK_ONLY=0

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --through) LABS=$(seq -s, 2 "$2"); shift 2 ;;
    --labs)    LABS="$2"; shift 2 ;;
    --check)   CHECK_ONLY=1; shift ;;
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
backup() { if [[ -e "$1" && ! -e "$1.orig" ]]; then cp -a "$1" "$1.orig"; ok "backed up $1 -> $1.orig"; fi; }
trap 'die "line $LINENO: \"$BASH_COMMAND\" failed - see $LOG"' ERR

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo bash $0"; exit 1; }
grep -qi ubuntu /etc/os-release || die "This script expects Ubuntu Server."
echo "---- $(date) : labs=$LABS check=$CHECK_ONLY ----" >> "$LOG"

if [[ "$IFACE" == auto ]]; then
  IFACE=$(ip -o -4 route show default 2>/dev/null | awk '{print $5; exit}')
  [[ -n "$IFACE" ]] || IFACE=$(ip -o link show | awk -F': ' '$2!="lo"{print $2; exit}')
fi
if [[ "$GATEWAY" == auto ]]; then
  GATEWAY=$(ip -o -4 route show default 2>/dev/null | awk '{print $3; exit}')
  [[ -n "$GATEWAY" ]] || GATEWAY="10.0.2.2"
fi

# ============================== verification =================================
check() {   # check "description" command...
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else warn "NOT OK: $d"; fi
}
verify() {
  say "Verification"
  want 2 && { check "hostname is $SERVER_HOSTNAME" test "$(hostname)" = "$SERVER_HOSTNAME"
              check "ssh service active" systemctl is-active --quiet ssh; }
  want 3 && { check "$IFACE has $SERVER_IP/$PREFIX" bash -c "ip -4 addr show $IFACE | grep -q '$SERVER_IP/$PREFIX'"
              check "internet reachable (ping 8.8.8.8)" ping -c 2 -W 2 8.8.8.8
              check "ufw disabled" bash -c "! systemctl is-active --quiet ufw"
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
  say "Log: $LOG"
}
if [[ $CHECK_ONLY -eq 1 ]]; then verify; exit 0; fi

say "Using interface $IFACE, gateway $GATEWAY, labs $LABS"

# ===================== packages first, while DHCP still works ================
say "Installing packages (done first, before the IP address changes)"
PKGS=(openssh-server ssh acl)
want 3 && PKGS+=(nftables fail2ban)
want 5 && PKGS+=(bind9 bind9-utils dnsutils)
export DEBIAN_FRONTEND=noninteractive
apt-get update -q >>"$LOG" 2>&1
apt-get install -y -q "${PKGS[@]}" >>"$LOG" 2>&1
ok "installed: ${PKGS[*]}"

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
fi

# ================================ LAB 3 ======================================
if want 3; then
  say "Lab 3 - nftables firewall and fail2ban"
  # Firewall first, so the IP change happens with the final ruleset in place.
  systemctl disable --now ufw >>"$LOG" 2>&1 || true
  ok "ufw disabled"
  backup /etc/nftables.conf
  cat > /etc/nftables.conf <<EOF
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
  systemctl enable --now fail2ban >>"$LOG" 2>&1 && ok "fail2ban installed and running (defaults; jail.conf untouched)"

  say "Lab 3 - static IP $SERVER_IP/$PREFIX on $IFACE"
  NP=/etc/netplan/50-cloud-init.yaml
  for f in /etc/netplan/*.yaml; do
    if [[ -e "$f" ]]; then backup "$f"; fi
  done
  # Stop cloud-init from rewriting the netplan file on the next boot.
  mkdir -p /etc/cloud/cloud.cfg.d
  echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
  # Remove other netplan files so only ours configures this interface (originals kept as .orig).
  for f in /etc/netplan/*.yaml; do
    if [[ -e "$f" && "$f" != "$NP" ]]; then mv "$f" "$f.disabled"; ok "moved aside $f"; fi
  done
  ns=$(printf '%s, ' "${UPSTREAM_DNS[@]}"); ns="${ns%, }"
  cat > "$NP" <<EOF
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
  chmod 600 "$NP"
  netplan generate || die "netplan rejected $NP - originals are in /etc/netplan/*.orig"
  ok "netplan file valid"
  netplan apply
  sleep 3
  ip -4 addr show "$IFACE" | grep -q "$SERVER_IP/$PREFIX" && ok "$IFACE now has $SERVER_IP/$PREFIX" || warn "address not applied yet - check: ip addr"
  ping -c 2 -W 2 8.8.8.8 >/dev/null 2>&1 && ok "internet reachable through $GATEWAY" \
    || warn "cannot reach 8.8.8.8 via $GATEWAY - see the Gateway note in the guide"
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
fi

# ================================ LAB 5 ======================================
if want 5; then
  say "Lab 5 - BIND9 for $DOMAIN"
  cd /etc/bind
  [[ -s /etc/bind/rndc.key ]] || { rndc-confgen -a >>"$LOG" 2>&1; ok "rndc.key generated"; }
  backup /etc/bind/named.conf
  mkdir -p /var/log/named
  chmod 770 /var/log/named
  chgrp bind /var/log/named
  ok "/var/log/named created (770, group bind)"
  fwd=$(printf '\t\t%s;\n' "${UPSTREAM_DNS[@]:0:2}")
  cat > /etc/bind/named.conf <<EOF
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
  cat > "/etc/bind/$DOMAIN.zone" <<EOF
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
  cat > "/etc/bind/$REVERSE_ZONE.zone" <<EOF
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
  chgrp bind "/etc/bind/$DOMAIN.zone" "/etc/bind/$REVERSE_ZONE.zone"
  chmod 644 "/etc/bind/$DOMAIN.zone" "/etc/bind/$REVERSE_ZONE.zone"
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
fi

verify
say "Done. Take a VirtualBox snapshot now (for example: 'Labs 2-5 complete')."
