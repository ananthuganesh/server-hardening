# Debian 13 Server Setup & Hardening

Two interactive Bash scripts that turn a fresh **Debian 13 (Trixie)** server into a hardened, production-ready host. They take you from a new server to this, with safety checks at every step that could lock you out:
- SSH on a port you choose, with key-only login;
- a firewall, intrusion prevention, kernel and audit hardening;
- automatic updates;
- the Caddy web server and Docker.

The scripts are **provider-neutral**: they work on any VPS or cloud server running Debian.

> [!WARNING]
> These scripts change SSH, the firewall and user accounts. Before you start, make sure your provider's **web / emergency console** works, and **never close your current SSH session** until the script confirms that the new connection works.

---

## Contents

- [Features](#features)
- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [After setup: final checks](#after-setup-final-checks)
- [What gets configured](#what-gets-configured)
- [Daily operations](#daily-operations)
- [Customizing defaults](#customizing-defaults)
- [Rerunning and upgrading](#rerunning-and-upgrading)
- [Troubleshooting and recovery](#troubleshooting-and-recovery)
- [Security notes and limitations](#security-notes-and-limitations)
- [Testing changes](#testing-changes)
- [Disclaimer](#disclaimer)

---

## Features

**Access**
- SSH on a port you choose, with key-only login using an **Ed25519 key generated on the server**, and root login disabled.
- A **10-minute automatic rollback** while you test the new SSH connection, so a mistake can't lock you out.

**Network protection**
- A **UFW** firewall: deny by default, with only web ports public.
- **CrowdSec** intrusion prevention with an nftables bouncer, reading SSH and web logs.
- **Container ports can't bypass the firewall**: containers publish on `127.0.0.1` by default, and extra rules guard anything published publicly.

**System hardening**
- Modern-only SSH cryptography, filtered to what the installed OpenSSH supports.
- Kernel `sysctl` hardening, unused kernel modules disabled, and `auditd` rules.
- AppArmor, password quality rules, disabled core dumps, and a secure umask.
- A root account that stays locked, but an emergency boot shell that still works from the provider console.

**Operations**
- **Automatic nightly updates** for Debian, CrowdSec, Caddy and Docker, with safeguards so configs are never overwritten.
- The **Caddy** web server with automatic HTTPS, plus a separate folder for your own sites.
- **Docker Engine** with a hardened daemon configuration.
- A **health check script** and a **Lynis** security audit (target score 83+; a test run scored 85).

---

## How it works

Setup runs in two phases, both **on the server**:

| Phase | Script | Runs as | What it does |
|---|---|---|---|
| 1 | `bootstrap.sh` | `root`, or `sudo` from the provider's default user | Upgrades the system packages, sets the hostname and timezone, creates your admin user, generates the SSH login key, and copies `setup.sh` into the admin user's home |
| 2 | `setup.sh` | The new admin user, with `sudo` | Hardens the whole system: SSH, firewall, CrowdSec, kernel, updates, Caddy and Docker |

The finished server is protected in layers:

```
Internet
   │
   ├─ Provider firewall / security group   (you set this; the script prints the rules)
   │    ├─ TCP 80, TCP 443  → allowed
   │    └─ everything else, including SSH → blocked
   │
   ├─ UFW firewall (on the server)
   │    ├─ deny incoming by default
   │    ├─ allow 80/tcp, 443/tcp
   │    └─ allow the SSH port
   │
   ├─ CrowdSec    bans attackers found in SSH and Caddy logs
   ├─ Caddy       automatic HTTPS, your sites in /etc/caddy/sites/
   └─ Containers  Docker, published on 127.0.0.1 by default

Admin computer
   └─ SSH on your chosen port  → admin login with the .pem key

Every night at 03:30 → automatic updates
```

---

## Requirements

- A **fresh Debian 13 server** from any provider. The scripts refuse other operating systems, and other Debian releases need a confirmation.
- **Root access**, or a default user with `sudo`.
- A **working emergency console** at your provider (web, VNC or serial console). Some providers require you to enable it first.
- **Optional:**
  - a [CrowdSec console](https://app.crowdsec.net) enrollment key;
  - a domain name for HTTPS sites.

---

## Quick start

In the commands below, replace these placeholders:

| Placeholder | Meaning |
|---|---|
| `SERVER_IP` | The server's public IP address |
| `ADMIN` | The admin username you choose in Phase 1 |
| `HOST` | The hostname you choose in Phase 1 |
| `SSH_PORT` | The SSH port you choose in Phase 2 |
| `LOGIN_KEY` | The key you use to log in to the fresh server today, for example your provider's key pair |

### 1. Prepare

1. Open your provider's **emergency console** and confirm it shows a login prompt. It's the fallback if SSH breaks.
2. Keep public SSH (port 22) open in your provider's firewall until setup is finished.

### 2. Get the scripts onto the server

Log in to the server, then clone the repository:

```bash
git clone https://github.com/ananthuganesh/server-setup.git
```
```bash
cd server-setup && chmod +x bootstrap.sh setup.sh
```

Or upload the two scripts from your computer:

```bash
scp -i LOGIN_KEY bootstrap.sh setup.sh root@SERVER_IP:~/
```

### 3. Run Phase 1: `bootstrap.sh`

```bash
sudo ./bootstrap.sh
```

Use plain `./bootstrap.sh` if you are already `root`. It asks for:

| Prompt | Notes |
|---|---|
| Server hostname | Press Enter to keep the current one |
| Admin username | Required; system accounts are refused |
| Admin password | At least 14 characters. **Save it in a password manager**: you need it for `sudo` and the emergency console |

The timezone is set to `Asia/Kolkata` automatically ([how to change it](#customizing-defaults)).

The script then generates an **Ed25519 login key** named `ADMIN-HOST.pem` and prints one command to download it. **Run it on your computer**, from the folder that contains `fetch-key.sh`:

```bash
./fetch-key.sh -i LOGIN_KEY root@SERVER_IP /root/ADMIN-HOST.pem
```

You need a copy of `fetch-key.sh` on your computer: clone this repository there, or download that one file. `fetch-key.sh` copies the key into `~/keys`, sets `chmod 600`, and checks that the file is a valid key. Use `-i` only if the login needs your provider's key. If you ran the script with `sudo` as the provider's default user, the command uses that user and the home folder instead. The script prints the exact command.

The server copy stays until you type `delete` at the prompt.

Test the new login from a **new terminal**:

```bash
ssh -i ~/keys/ADMIN-HOST.pem -o IdentitiesOnly=yes ADMIN@SERVER_IP
```

Once that login works, go back to the script and type `delete` to shred the server copy of the private key. You can also type `show` to print the key, useful from a web console, or `keep`.

> [!TIP]
> The key has no passphrase. To add one on your computer, run `ssh-keygen -p -f ~/keys/ADMIN-HOST.pem`.

### 4. Run Phase 2: `setup.sh`

Logged in as your new admin user:

```bash
cd ~ && sudo ./setup.sh
```

It asks, in this order:

| Prompt | What to do |
|---|---|
| SSH port | Type the port you want (1024–65535). Nothing is suggested; on a rerun, press Enter to keep the port sshd already uses |
| **SSH verification** | Keep this terminal open. From a **new terminal on the admin computer**, run the command it shows: `ssh -i ~/keys/ADMIN-HOST.pem -o IdentitiesOnly=yes -p SSH_PORT ADMIN@SERVER_IP`. If it works, type `yes`. If not, type `no` to roll back |
| CrowdSec enrollment key | Optional; press Enter to skip |
| Provider firewall | Set the rules it prints in your provider's firewall, then type `done`. Or type `not` (not yet) or `skip` (your provider has no firewall) |

Before any of these, Phase 2 checks that the admin user has a valid SSH key, and asks you to set a password if the user has none.

Two more prompts appear only in some cases: a warning asking whether to continue when you run `setup.sh` as a user other than the admin, and a question about switching from Nginx to Caddy when custom Nginx sites exist.

Phase 2 ends with a Lynis security audit and a summary of how to reach the server.

---

## After setup: final checks

1. **Health check**:
   ```bash
   ~/check-health.sh
   ```
2. **Reboot test**: after `sudo reboot`, reconnect:
   ```bash
   ssh -i ~/keys/ADMIN-HOST.pem -o IdentitiesOnly=yes -p SSH_PORT ADMIN@SERVER_IP
   ```
3. **Root is refused**: `ssh root@SERVER_IP -p SSH_PORT` should fail.
4. **Emergency console**: log in with the admin password. This is the fallback if SSH breaks.
5. **Retire the provider's default user**, if your image has one, once everything above works:
   ```bash
   sudo rm /home/DEFAULT_USER/.ssh/authorized_keys
   ```
   ```bash
   sudo usermod --expiredate 1 DEFAULT_USER
   ```
   Also remove that user's passwordless-sudo file in `/etc/sudoers.d/`, after checking the file only covers that user.

---

## What gets configured

### Base system

- **Tools:** `btop`, `htop`, `iotop`, `tmux`, `jq`, `curl`, `wget`, `git`, `vim`, `rsync`, `ncdu`, `tree`, `lsof`, `tcpdump`, `mtr-tiny`, `traceroute`, `ripgrep`, `fd-find` (the command is `fdfind`), `plocate`, DNS tools and more.
- **Locale:** `en_US.UTF-8` is verified after generation, and built directly with `localedef` if `locale-gen` failed silently.
- **Time sync:** `systemd-timesyncd` is enabled if no time sync service is running.
- **rsyslog:** routes SSH logs, including Debian 13's `sshd-session` process, to `/var/log/auth.log`.
- **Hostname:** on cloud-init images, `/etc/cloud/cloud.cfg.d/99-preserve-hostname.cfg` keeps it across reboots.
- **Swap:** `/swapfile` sized to RAM (2 GB up to 2 GB of RAM, equal to RAM up to 8 GB, capped at 8 GB), with `vm.swappiness = 10` and `vm.vfs_cache_pressure = 50`.

### Access: key-only SSH

SSH accepts connections from any address on your chosen port. The protection is:

- **Key-only login** with the `.pem` key. Passwords are refused, and root login is disabled.
- **`AllowUsers`** limits SSH to the admin user, plus any other admin you added.
- **CrowdSec** bans addresses that fail repeatedly ([details](#crowdsec)).
- **Protect the key.** It's the only way in. Add a passphrase on your computer with `ssh-keygen -p`.
- **Emergency console:** your provider's console is the fallback if SSH breaks. Set it up before you start (see [Prepare](#1-prepare)).

### SSH

<details>
<summary><b>Generated <code>/etc/ssh/sshd_config</code></b></summary>

```ini
Port SSH_PORT

HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_rsa_key

KexAlgorithms mlkem768x25519-sha256,sntrup761x25519-sha512,sntrup761x25519-sha512@openssh.com,curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group18-sha512,diffie-hellman-group16-sha512,diffie-hellman-group-exchange-sha256
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com
HostKeyAlgorithms ssh-ed25519,ssh-ed25519-cert-v01@openssh.com,sk-ssh-ed25519@openssh.com,sk-ssh-ed25519-cert-v01@openssh.com,rsa-sha2-512,rsa-sha2-512-cert-v01@openssh.com,rsa-sha2-256,rsa-sha2-256-cert-v01@openssh.com

PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PubkeyAuthentication yes
AuthenticationMethods publickey
HostbasedAuthentication no
GSSAPIAuthentication no
UsePAM yes
AuthorizedKeysFile .ssh/authorized_keys
AllowUsers ADMIN
MaxAuthTries 3
MaxSessions 2
MaxStartups 10:30:60
LoginGraceTime 20
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
PermitUserEnvironment no
PermitTunnel no
TCPKeepAlive no
Compression no
IgnoreRhosts yes
DebianBanner no
Banner /etc/issue.net
SyslogFacility AUTH
LogLevel VERBOSE
PrintMotd no
PrintLastLog yes
StrictModes yes
ClientAliveInterval 300
ClientAliveCountMax 2

Include /etc/ssh/sshd_config.d/*.conf

Subsystem sftp /usr/lib/openssh/sftp-server
```

The algorithm lists are filtered against `ssh -Q`, so the file only contains algorithms the installed OpenSSH supports.
</details>

- **Modern cryptography only:** post-quantum hybrid and Curve25519 key exchange, AEAD ciphers and encrypt-then-MAC. Weak Diffie-Hellman moduli (under 3072 bits) are removed, and RSA host keys under 3072 bits are regenerated.
- **Your key type isn't restricted,** so existing Ed25519, RSA, ECDSA and hardware keys keep working. Very old clients that only support CBC ciphers can no longer connect.
- **Cloud-image drop-ins can't override these settings.** The hardened lines come before the `Include`, and the script verifies the effective settings with `sshd -T`.
- **No `ListenAddress`**, on purpose. Binding sshd to one interface can stop it from starting at boot if that interface isn't up yet.

**Lockout protection:**
1. **Pre-flight checks:** the admin user must have a valid key and a password before anything changes.
2. **Snapshot and rollback timer:** the current SSH config and firewall rules are saved, and a 10-minute automatic rollback is armed.
3. **Validation:** the new config must pass `sshd -t`, SSH must be running, and the new port must be listening.
4. **Your confirmation:** you test the login from a new terminal and type `yes`. If you're too late and the rollback already ran, the script stops instead of pretending the server is hardened.
5. **Rollback:** it restores the state from **just before this run**, so a rerun on a hardened server restores the saved config instead of reopening port 22.

### Firewalls

<details>
<summary><b>UFW rules</b></summary>

```bash
ufw default deny incoming
ufw default allow outgoing
ufw default deny forward
ufw allow 80/tcp  comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw allow SSH_PORT/tcp comment 'SSH'
```
</details>

**Provider firewall.** At the end of Phase 2, the script prints these rules for your provider's firewall or security group:

| Rule | Why |
|---|---|
| Allow TCP 80 from `0.0.0.0/0` and `::/0` | HTTP and HTTPS certificate issuance |
| Allow TCP 443 from `0.0.0.0/0` and `::/0` | HTTPS |
| **Allow TCP SSH_PORT from `0.0.0.0/0` and `::/0`** | SSH, key-only login |
| **Remove TCP 22** | The default SSH port is no longer used |
| Allow all outbound | Updates, CrowdSec, Docker |

Your answer (`done`, `not` or `skip`) is saved in `/var/lib/server-setup/provider-firewall`. If it's `not`, `check-health.sh` keeps reminding you. When you've set the rules, mark it done with:
```bash
echo done | sudo tee /var/lib/server-setup/provider-firewall
```

### CrowdSec

- **Components:** the official engine plus the **nftables firewall bouncer**, with the `linux`, `sshd` and `caddy` collections. The hub updates daily.
- **Log sources:** `/var/log/auth.log`, `/var/log/syslog` and the Caddy access log. SSH events are read once, so failed logins aren't counted twice.
- **Debian 13 support:** a custom parser handles Debian 13's `sshd-session` log lines.
- **Optional:** enrollment in the CrowdSec console.

### Kernel, accounts and auditing

- **Root:** the account is locked. The systemd emergency and rescue shells still open on the console (`SYSTEMD_SULOGIN_FORCE=1`), so a boot problem doesn't leave you stuck.
- **Packages:** AppArmor, `auditd`, `rkhunter`, `lynis`, `debsums` (weekly), `sysstat`, `acct`, `needrestart`, `apt-listbugs`, `apt-listchanges` and `libpam-tmpdir`.
- **Passwords** (`pam_pwquality`): at least 14 characters from 3 character classes, with a dictionary check.
- **`/etc/login.defs`:** `UMASK 027`, SHA-crypt rounds 10000–65536, and passwords expire after at most 365 days.
- **Login shells:** umask `027`, core dumps disabled, and a legal banner on the console and SSH.
- **Kernel modules disabled:** `usb-storage`, `firewire-ohci`, `dccp`, `sctp`, `rds` and `tipc`.

<details>
<summary><b><code>/etc/sysctl.d/99-hardening.conf</code></b></summary>

```conf
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 5
kernel.kptr_restrict = 2
kernel.sysrq = 0
kernel.core_uses_pid = 1
fs.suid_dumpable = 0
kernel.dmesg_restrict = 1
kernel.perf_event_paranoid = 3
net.core.bpf_jit_harden = 2
kernel.unprivileged_bpf_disabled = 1
kernel.yama.ptrace_scope = 1
fs.protected_fifos = 2
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_regular = 2
dev.tty.ldisc_autoload = 0
```

IP forwarding is intentionally **not** disabled, because Docker needs it. Forwarded traffic is filtered by UFW and the Docker firewall rules instead.
</details>

<details>
<summary><b><code>/etc/audit/rules.d/hardening.rules</code></b></summary>

```
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/sudoers -p wa -k sudoers
-w /etc/sudoers.d/ -p wa -k sudoers
-w /etc/ssh/sshd_config -p wa -k sshd_config
-w /etc/ssh/sshd_config.d/ -p wa -k sshd_config
-w /etc/crontab -p wa -k cron
-w /var/spool/cron -p wa -k cron
-a always,exit -F arch=b64 -S init_module,finit_module,delete_module -k modules
-a always,exit -F arch=b64 -S execve -F euid=0 -k root_commands
-w /home/ADMIN/.ssh/authorized_keys -p wa -k ssh_keys
-a always,exit -F arch=b32 -S execve -F euid=0 -k root_commands   # x86_64 only
```

Search the audit log with, for example, `sudo ausearch -k root_commands -i`.
</details>

### Automatic updates

Updates use Debian's `unattended-upgrades` on its systemd timers, not a raw cron job. It holds the package manager lock, repairs interrupted runs and logs everything.

| Setting | Value |
|---|---|
| What updates | Debian (stable, point releases, security), CrowdSec, Caddy and Docker |
| When | Package lists at 02:30, installs at **03:30 server time**. A missed window is skipped |
| Config files | Kept (`--force-confold`), so an upgrade never resets `sshd_config`, UFW rules or the Caddyfile |
| Services | `needrestart` restarts services that still use old libraries |
| Reboots | **Manual**. `check-health.sh` shows when a reboot is needed |

At the end, Phase 2 verifies that every repository is covered and runs a dry run.

### Caddy web server

- **Install and HTTPS:** installed from Caddy's official repository, with automatic HTTPS for real domain names. HTTP/3 is turned off, so only TCP 443 is used.
- **`/etc/caddy/Caddyfile`** is managed by the script and replaced on reruns. It holds:
  - the shared `site_defaults` snippet: compression, security headers including HSTS, no `Server` header, a JSON access log, and a 404 for dotfiles such as `.git` and `.env`;
  - port 80 answers `/health` and returns an empty 404 for any other request to the IP.
- **`/etc/caddy/sites/*.caddy`** holds **your sites**. The script never touches these files.
- **Validation:** new configs are validated before they're used, so a broken site file never takes the web server down.

Add a site, for example a container published on `127.0.0.1:3000`:

```bash
sudo tee /etc/caddy/sites/example.com.caddy >/dev/null <<'EOF'
example.com {
	import site_defaults
	reverse_proxy 127.0.0.1:3000
}
EOF
```
```bash
sudo caddy validate --config /etc/caddy/Caddyfile && sudo systemctl reload caddy
```

Point the domain's DNS at the server first; Caddy then gets the certificate automatically.

### Containers: Docker

Docker Engine and the Compose plugin come from Docker's own repository, which is also added to the nightly updates. The admin user joins the `docker` group, so containers run without `sudo`.

<details>
<summary><b><code>/etc/docker/daemon.json</code></b></summary>

```json
{
  "iptables": true,
  "ip6tables": true,
  "ip": "127.0.0.1",
  "icc": false,
  "no-new-privileges": true,
  "live-restore": true,
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
```
</details>

| Setting | Effect |
|---|---|
| `"ip": "127.0.0.1"` | `-p 3000:80` is reachable only from the server itself, for example by Caddy. To publish publicly on purpose, use `-p 0.0.0.0:3000:80` |
| `"icc": false` | Containers on the default bridge network can't talk to each other; Compose networks still can |
| `"no-new-privileges": true` | Processes inside containers can't gain extra privileges |
| `"live-restore": true` | Containers keep running while Docker restarts or upgrades |

- **Firewall rules:** Docker's own iptables rules normally bypass UFW. The script adds [ufw-docker](https://github.com/chaifeng/ufw-docker)-style rules to `/etc/ufw/after.rules`, so new public connections to containers are dropped. To expose a container port publicly on purpose, allow it with `sudo ufw route allow proto tcp from any to any port CONTAINER_PORT`.
- **Port 8080 is taken:** don't publish containers on host port 8080, because CrowdSec's local API uses it.

---

## Daily operations

```bash
~/check-health.sh
```

The health check reports:
- Docker containers;
- disk, RAM and swap usage;
- CrowdSec bans and recent failed SSH logins;
- Caddy status;
- automatic update runs;
- SSH port and whether UFW allows it;
- whether a reboot is needed;
- the Lynis score;
- the provider firewall status.

**Updates and reboots**
```bash
systemctl list-timers apt-daily-upgrade.timer
```
```bash
sudo unattended-upgrade --dry-run --debug
```
```bash
sudo reboot
```
The first shows the next automatic update, and the second shows what would be updated now. Reboot when `check-health.sh` says a reboot is needed.

**CrowdSec**
```bash
sudo cscli decisions list
```
```bash
sudo cscli decisions delete --ip 1.2.3.4
```
```bash
sudo cscli metrics
```
These list active bans, unban an IP, and show log processing statistics.

**Security audit**
```bash
sudo lynis audit system --quick
```

---

## Customizing defaults

| Setting | Default | Where to change it |
|---|---|---|
| Timezone | `Asia/Kolkata` | `TIMEZONE_VAL` in `bootstrap.sh` |
| Local key folder in printed commands | `~/keys` | `LOCAL_KEY_DIR` in `bootstrap.sh` |
| Update window | 03:30 | `/etc/systemd/system/apt-daily-upgrade.timer.d/override.conf` on the server |
| Automatic reboots | Off | Set `Unattended-Upgrade::Automatic-Reboot "true";` in `/etc/apt/apt.conf.d/50unattended-upgrades` |
| Lynis target score | `83` | `LYNIS_TARGET_SCORE` in `setup.sh` |

---

## Rerunning and upgrading

Both scripts are safe to run again.

- **`bootstrap.sh`:**
  - It asks before replacing an existing user's password and key, and backs up `authorized_keys` first.
  - On a hardened server, it prints commands that use the server's address and SSH port.
  - It offers to add new admins to `AllowUsers`.
- **`setup.sh`:**
  - SSH port prompt: on a rerun, pressing Enter keeps the current port. The provider firewall question isn't asked again once answered `done` or `skip`.
  - Existing admins stay in `AllowUsers`.
  - Changing the SSH port closes the old firewall rule.

**Servers set up by older versions:**
- **Nginx:** Phase 2 disables Nginx and switches to Caddy, asking first if Nginx serves custom sites. The package and `/etc/nginx` are kept.
- **`ListenAddress` lines:** leftover lines from older versions are removed from `sshd_config`.

---

## Troubleshooting and recovery

If you can't reach the server over SSH, log in through your **provider's emergency console** with the admin password. Then check the port with `sudo sshd -T | grep -i '^port'` and the firewall with `sudo ufw status`.

| Problem | Fix |
|---|---|
| `Permission denied (publickey)` | Use `-i ~/keys/ADMIN-HOST.pem -o IdentitiesOnly=yes`. With several keys in your SSH agent, the server's limit of 3 attempts runs out before the right key |
| `setlocale: cannot change locale` | Run `sudo localedef -i en_US -f UTF-8 en_US.UTF-8`, then log in again |
| Banned by CrowdSec | Run `cscli decisions list`, then `cscli decisions delete --ip YOUR_IP` |
| Firewall blocks you | Run `ufw disable`, fix the rules, then `ufw enable` |
| Undo the last SSH change | Run `cp /etc/ssh/sshd_config.pre-run /etc/ssh/sshd_config && systemctl restart ssh`. The original distro config is in `sshd_config.bak` |
| Boot stuck in emergency mode | The console opens a root shell. Fix `/etc/fstab` or the failed mount, then reboot |
| Lost the `.pem` key | From the console, rerun `bootstrap.sh`, reconfigure the user, and copy the new key with `show` |
| Old SSH client rejected | Update the client; the server allows only modern algorithms |
| Undo the Docker firewall rules | Delete the `# BEGIN UFW AND DOCKER` … `# END UFW AND DOCKER` block in `/etc/ufw/after.rules`, then run `ufw reload` |

---

## Security notes and limitations

- **SSH is open to the internet**, protected by key-only login. Keep the key secret, use a passphrase, keep packages updated, and watch CrowdSec.
- **The `docker` group is root-equivalent.** The admin user is a member, so anyone who can log in as that user can become root through Docker. Protect the SSH key with a passphrase, or remove the user from the group (`sudo gpasswd -d ADMIN docker`) and use `sudo docker`.
- **Reboots are manual.** Kernel fixes only apply after a reboot.
- **Not included:**
  - backups;
  - alerting;
  - off-server log storage;
  - outbound traffic filtering;
  - file-integrity monitoring (AIDE);
  - immutable audit rules.
- **The `.pem` key is created on the server.** Delete the server copy as soon as your login works.
- **Never commit secrets:** private keys, auth keys, enrollment keys or real server addresses. `.gitignore` blocks common key files.

---

## Testing changes

There is no automated test suite. Before committing:

```bash
bash -n bootstrap.sh setup.sh
```
```bash
shellcheck bootstrap.sh setup.sh
```

The only complete test is running both phases on a disposable Debian 13 server with the provider's emergency console open.

---

## Disclaimer

These scripts make deep changes to a server's security configuration. Review them before use, test on a disposable server first, and use them at your own risk.
