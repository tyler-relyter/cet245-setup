# cet245-setup
Catch-up and repair scripts for CET 245 Internet Servers. They bring the Ubuntu Server
and Ubuntu Client lab VMs to the end state of any lab from 2 through 10, and fix a VM
whose earlier labs were done wrong.

| Script | Run on | Covers |
|---|---|---|
| `cet245_server_setup.sh` | Ubuntu Server, as root | Labs 2-10 |
| `cet245_client_setup.sh` | Ubuntu Client (Desktop), with sudo | client side of Labs 2-10 |

Run the server script first, then the client script. Read the guide
(`CET245_Environment_Setup_Guide_Labs1-5.docx`) for how to get started.

## Server
```
sudo bash cet245_server_setup.sh                 # Labs 2-10
sudo bash cet245_server_setup.sh --from 6        # VM is good through Lab 5: do 6-10
sudo bash cet245_server_setup.sh --through 5     # Labs 2-5 only
sudo bash cet245_server_setup.sh --labs 8,9      # only these labs
sudo bash cet245_server_setup.sh --check         # verify only, change nothing
```
Options: `--user NAME` (lab account, default `student`), `--name "First Last"`
(name placed on web pages and for-transfer.txt the script creates).

Run from the VM console when Lab 3 is included (it changes the IP address).
`--from 6` is safe over SSH.

| Lab | What the server script does |
|---|---|
| 2 | hostname, root password, ssh |
| 3 | nftables (trusted 10.0.2.0/24 set), fail2ban, static 10.0.2.5/24 |
| 4 | instructor/lecturer, faculty, Labs dir 740 + ACL, %faculty sudo |
| 5 | BIND9 for classroom.edu, forward and reverse zones, resolved.conf |
| 6 | sshd: PasswordAuthentication yes, PermitRootLogin no, StrictModes yes, PubkeyAuthentication yes; UFW on (OpenSSH + the 10.0.2.0/24 lab network + DNS); student's `~/.ssh/config` Host server; `for-transfer.txt` |
| 7 | ntpsec and at; root crontab (MAILTO, PATH, monthly update, log cleanup, Friday disk report, @reboot); student's Sunday backup to `/backups/home_backup`; `/root/rules.good` for the at step |
| 8 | `/srv/www`, webdev user, Apache config and modules (then stopped and disabled), Nginx with `nginx.conf` and `classroom.conf` |
| 9 | PHP-FPM pool `server.conf` (port 9000), www-server user, `/srv/www/server.classroom.edu` with ACLs, `000-server.conf`, info.php |
| 10 | self-signed `classroom.crt`/`classroom.key`, HTTPS in `000-server.conf`, HTTP redirects to HTTPS |

## Client
```
sudo bash cet245_client_setup.sh
sudo bash cet245_client_setup.sh --check
```
Static 10.0.2.15/24 with the server as DNS, `/etc/hosts` entry for classroom.edu,
key pair `~/.ssh/key-student-server`, `~/.ssh/config` Host server with the
IdentityFile, the key copied to the server, `for-transfer.txt` copied into
`~/Downloads`, lynx, and an HTTPS check.

## How repairs work
- Before installing anything, both scripts disable a leftover installer (cdrom) package
  source, check internet by IP and **name resolution** (the lookup `ping` and `apt` use),
  and repair `/etc/resolv.conf` / systemd-resolved if names fail. As a last resort they add
  a temporary DNS server so the installs can run.
- The client checks that the server's BIND answers both `classroom.edu` and internet
  names. If it only answers `classroom.edu`, 1.1.1.1 is added as a temporary second DNS
  server; `--check` warns while it is still there. `--check` on either VM prints a name
  resolution report (each DNS server, and whether public DNS is reachable) when names fail.
- Each step checks the current state first; re-running is safe.
- Files the script replaces are copied to `/var/backups/cet245/<date-time>/` first.
- Student-written content (`index.html`, `info.php`, `for-transfer.txt`) is created
  only when missing, never overwritten.
- Broken copies of the Lab 7 cron jobs (for example `/var/logs`, or `apt update`
  without `upgrade`) are replaced instead of duplicated; other cron jobs are kept.
- Nginx sites and PHP-FPM pools that aren't part of the labs' final setup are set
  aside (into the backup folder) when they would break `nginx -t` or clash on port 9000.
- The PHP version is detected (8.3 on 24.04, newer on later releases).
- `/var/lib/cet245/lab<N>.done` records which labs the script completed; `--check` lists them.

Log: `/var/log/cet245-setup.log`

These are instructor tools: the scripts do the configuration, not the learning.
Students still owe every screenshot and written answer.
