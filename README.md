# Debian 13 (Trixie) — Semi-Automated Production Server Hardening Suite

> ⚠️ **READ BEFORE STARTING**
> Steps are ordered to prevent lockouts. Never close an active SSH session until you verify the new connection works. Keep your Hetzner Cloud Console open as a fallback at all times.

This directory contains a semi-automated, secure production server hardening suite designed to transform a fresh Debian 13 (Trixie) server into a highly secure, hardened environment in two logical phases with robust interactive checks.

By running these scripts, you avoid copy-paste errors, automate complex kernel and security configurations, configure RAM-based swap, set up packet filtering, configure threat intelligence via **CrowdSec**, install **Nginx** with a clean default site, and install **Docker** with secure isolation, guarded by interactive SSH lockout verification checks.

---

## Table of Contents
1. [Architecture & Firewall Layers](#1-architecture--firewall-layers)
2. [⚡ Quick Start: Semi-Automated Script Setup (Recommended)](#2-quick-start-semi-automated-script-setup-recommended)
3. [📖 Detailed Hardening Guide & Reference Manual](#3-detailed-hardening-guide--reference-manual)
   * [First Login & Bootstrapping](#step-1-first-login--user-creation)
   * [Base System Tuning](#step-2-base-system-setup)
   * [Swap Sizing](#swap-sizing-automatic)
   * [Tailscale Mesh Deployment](#step-3-mesh-vpn-tailscale)
   * [SSH Hardening & Safe Gating](#step-4-ssh-hardening)
   * [UFW Local Packet Filtering](#step-5-ufw-firewall)
   * [Cloud-Level Hetzner Firewall](#step-6-hetzner-cloud-firewall)
   * [System IPS (Official CrowdSec Version)](#step-7-crowdsec-intrusion-prevention-system)
   * [Kernel & Auditing Controls (auditd)](#step-8-kernel-hardening--sysctl)
   * [Nginx Web Server Setup](#step-9-nginx-web-server-setup)
   * [Docker Engine Setup](#step-10-docker-engine-setup)
4. [🛠️ Daily Operations & Diagnostics](#4-daily-operations--diagnostics)
5. [🚑 Emergency Recovery & Disaster Actions](#5-emergency-recovery--disaster-actions)

---

## 1. Architecture & Firewall Layers

The server operates a multi-layered security grid, sealing all administrative assets behind an encrypted Tailscale tunnel and exposing only essential public web ports (80/443).

```
Internet
   │
   ├─ Hetzner Cloud Firewall     ← Layer 1: network level (configured in Hetzner Console)
   │   ├─ TCP 80/443 → allowed from anywhere
   │   ├─ TCP 2626   → Tailscale subnets only (100.64.0.0/10)
   │   └─ all else   → dropped at hypervisor level
   │
   ├─ UFW Firewall               ← Layer 2: OS level (automatically configured)
   │   ├─ default deny incoming
   │   ├─ allow 80, 443
   │   └─ allow 2626 on tailscale0 interface only
   │
   ├─ CrowdSec IPS               ← Layer 3: threat intelligence (installed & tuned)
   │   ├─ OpenSSH Trixie custom sshd-session parser
   │   └─ nftables bouncer enforces active bans
   │
   ├─ Nginx Web Server           ← Layer 4: default HTTP site
   │   ├─ serves /var/www/html on port 80
   │   └─ exposes /health for local checks
   │
   └─ Docker Engine              ← Layer 5: ready for future containers

Tailscale VPN (100.x.x.x)
   └─ SSH :2626      → admin access (selected admin user only)
```

---

## 2. ⚡ Quick Start: Semi-Automated Script Setup (Recommended)

To run the semi-automated hardening cycle, use the provided scripts (`bootstrap.sh` and `setup.sh`) located in this directory. Phase 1 creates the administrative user and places Phase 2 in that user's home directory. Phase 2 performs the system hardening, with interactive checkpoints before the lockout-sensitive steps continue.

### Step A: Open Hetzner Emergency Console
1. Log in to [console.hetzner.cloud](https://console.hetzner.cloud).
2. Click your active server node → click **Console** (top right). Keep this open as an emergency backup.
3. Do **not** apply a restrictive Hetzner Cloud Firewall yet. Keep normal public SSH reachable until Phase 2 confirms Tailscale SSH and you complete one reboot/reconnect test.

### Step B: Upload Scripts to the Target Server
From your **local machine (MacBook)**:
```bash
scp bootstrap.sh setup.sh root@YOUR_SERVER_PUBLIC_IP:/root/
```

### Step C: Execute Phase 1 — Environment Bootstrapping (Run as `root`)
SSH into your server as root via public IP and execute:
```bash
chmod +x bootstrap.sh setup.sh
./bootstrap.sh
```
* **Interactive Prompts**: The script asks for the administrative username, then prompts you to set a secure password and paste your local SSH public key (e.g., `ssh-ed25519 AAAAC3...`). The default username is `ananthu` if you press Enter.
* **Keep the root session open** until you confirm that the new `YOUR_ADMIN_USER` SSH login works from another terminal.
* **Rerun behavior**: If the admin user already exists and you choose not to reconfigure the password/key, Phase 1 still refreshes `setup.sh` in that user's home directory.
* **Public IP output**: At the end, `bootstrap.sh` tries Hetzner metadata first, then a generic public-IP lookup, then local route detection, and prints the real `ssh YOUR_ADMIN_USER@SERVER_PUBLIC_IP` command when detection succeeds.

### Step D: Execute Phase 2 — System Hardening (Run as `YOUR_ADMIN_USER`)
Open a **new terminal** on your local machine and connect as the newly created admin user:
```bash
ssh YOUR_ADMIN_USER@YOUR_SERVER_PUBLIC_IP
```
Execute the main configuration and security hardening suite with `sudo` from your home directory (where `bootstrap.sh` automatically copied it with correct permissions):
```bash
cd ~
sudo ./setup.sh
```

#### 💡 Safe Interactive Checkpoints in Phase 2:
1. **Administrative username**: The script defaults to the user that started `sudo ./setup.sh`, then asks you to confirm or enter the target admin username.
2. **Hostname**: The script asks for a server hostname and defaults to `core` if you press Enter.
3. **Tailscale login**: The script runs `tailscale up --ssh --accept-dns=true --accept-routes=true`, prints a unique Tailscale login URL, and waits up to 2 minutes for activation. If Tailscale fails or times out, the script stops before touching SSH.
4. **UFW & SSH Verification Gate**: The script arms a 10-minute automatic rollback, moves SSH to port `2626`, restricts that port to the Tailscale interface in UFW, and pauses.
   * **Keep your current terminal open.**
   * Open a **NEW local terminal** on your MacBook and run: `ssh -p 2626 YOUR_ADMIN_USER@YOUR_TAILSCALE_IP`.
   * If it connects, enter **`yes`** to cancel the rollback timer, complete setup, and lock down root.
   * If it fails, enter **`no`**. The script restores your previous SSH config and disables UFW entirely to ensure you are not locked out.
   * If your session dies before you answer, the rollback timer restores the previous SSH config and disables UFW automatically after 10 minutes.
5. **CrowdSec Console Key**: The script prompts for your CrowdSec dashboard enrollment key. Paste it to register the node, or press Enter to skip.

---

## 3. 📖 Detailed Hardening Guide & Reference Manual

### Step 1: First Login & User Creation
To manually configure users, connect as `root` and run:
```bash
ADMIN_USER="youradmin"
adduser "$ADMIN_USER"
usermod -aG sudo "$ADMIN_USER"

# Set up SSH directory
mkdir -p "/home/$ADMIN_USER/.ssh"
chmod 700 "/home/$ADMIN_USER/.ssh"
nano "/home/$ADMIN_USER/.ssh/authorized_keys" # Paste your public key here
chmod 600 "/home/$ADMIN_USER/.ssh/authorized_keys"
chown -R "$ADMIN_USER:$ADMIN_USER" "/home/$ADMIN_USER/.ssh"
```

### Step 2: Base System Setup
On Debian 13, sbin tools are excluded from the default user PATH. Add them to `.bashrc`:
```bash
echo 'export PATH="/usr/local/sbin:/usr/sbin:/sbin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```
Configure timedate metrics, log forwarding, and upgrade the OS:
```bash
sudo timedatectl set-timezone Asia/Kolkata
sudo hostnamectl set-hostname YOUR_HOSTNAME # automated default: core
sudo apt install -y locales
sudo sed -i 's/^[#[:space:]]*en_US\.UTF-8[[:space:]]\+UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
sudo locale-gen en_US.UTF-8
sudo update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
printf 'LANG=en_US.UTF-8\nLC_ALL=en_US.UTF-8\n' | sudo tee /etc/default/locale
printf '\n# UTF-8 locale for terminal applications such as btop\nexport LANG=en_US.UTF-8\nexport LC_ALL=en_US.UTF-8\n' >> ~/.bashrc

sudo apt update && sudo apt upgrade -y

# Install essential admin and diagnostics tools
sudo apt install -y \
  btop htop tmux jq curl wget git nano vim less \
  unzip zip tar rsync ncdu tree lsof psmisc \
  net-tools dnsutils traceroute mtr-tiny ripgrep fd-find

# Configure traditional logging redirect for sshd
sudo apt install rsyslog -y
sudo systemctl enable --now rsyslog

sudo nano /etc/rsyslog.d/ssh-auth.conf
# Paste:
# if $programname == 'sshd' or $programname == 'sshd-session' then {
#     action(type="omfile" file="/var/log/auth.log" Template="RSYSLOG_TraditionalFileFormat")
#     stop
# }
sudo systemctl restart rsyslog
```

#### Swap Sizing (Automatic)
The automated script creates or resizes `/swapfile` to reach a safe total swap target based on detected RAM:

* `<= 2 GB RAM` -> `2 GB` total swap
* `3-8 GB RAM` -> swap equal to RAM
* `> 8 GB RAM` -> `8 GB` total swap cap

For the current 4 GB server class, the target is `4 GB` total swap. The script persists `/swapfile` in `/etc/fstab` only when it is actually active, then applies conservative swap tuning in `/etc/sysctl.d/60-swap.conf`:

```conf
vm.swappiness = 10
vm.vfs_cache_pressure = 50
```

Useful verification commands:
```bash
free -h
swapon --show
cat /etc/sysctl.d/60-swap.conf
```

### Step 3: Mesh VPN (Tailscale)
Tailscale must be active before hardening ports to ensure a secure route:
```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --ssh --accept-dns=true --accept-routes=true
tailscale ip -4 # Retrieve your VPN IP (e.g. 100.116.117.35)
```
The automated script stops if `tailscale up` fails or if Tailscale does not become active within 2 minutes.

### Step 4: SSH Hardening
Edit `/etc/ssh/sshd_config`:
```ini
Port 2626
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
AllowUsers YOUR_ADMIN_USER
MaxAuthTries 3
MaxSessions 2
LoginGraceTime 20
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
TCPKeepAlive no
PermitTunnel no
IgnoreRhosts yes
SyslogFacility AUTH
LogLevel VERBOSE
PrintLastLog yes
StrictModes yes
ClientAliveInterval 300
ClientAliveCountMax 2
Include /etc/ssh/sshd_config.d/*.conf
Subsystem sftp /usr/lib/openssh/sftp-server
```
*Validate config with `sudo sshd -t` and restart with `sudo systemctl restart ssh`.*

SSH intentionally does **not** use `ListenAddress YOUR_TAILSCALE_IP`; at boot, SSH can start before `tailscale0` has its IP address. UFW enforces the Tailscale-only restriction with an interface-scoped rule instead.

Before changing SSH/UFW, the automated script schedules an emergency rollback with `systemd-run`. If the new SSH connection is not confirmed within 10 minutes, `/etc/ssh/sshd_config.bak` is restored and UFW is disabled so public rescue SSH can work again.

### Step 5: UFW Firewall
```bash
sudo apt install ufw -y
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw default deny forward

# Allow public web traffic
sudo ufw allow 80/tcp comment 'HTTP'
sudo ufw allow 443/tcp comment 'HTTPS'

# Allow SSH only on Tailscale
sudo ufw allow in on tailscale0 to any port 2626 proto tcp comment 'SSH via Tailscale only'
sudo ufw enable
```

### Step 6: Hetzner Cloud Firewall
Define these rules inside your Hetzner Cloud Console dashboard:
* **Inbound HTTP**: TCP `80` from `0.0.0.0/0` and `::/0`
* **Inbound HTTPS**: TCP `443` from `0.0.0.0/0` and `::/0`
* **Inbound SSH**: TCP `2626` from `100.64.0.0/10` (Tailscale internal subnet)
* **Outbound**: Leave entirely empty to allow all outbound traffic.

### Step 7: CrowdSec Intrusion Prevention System
To install the official, up-to-date repository version and connect console metrics:
```bash
# 1. Install Official Redirect Installer
curl -s https://install.crowdsec.net | sudo bash

# 2. Install CrowdSec engine
sudo apt update
sudo apt install crowdsec -y

# 3. Install nftables firewall bouncer
sudo apt install crowdsec-firewall-bouncer-nftables -y

# If the bouncer was installed before crowdsec, generate a key and finish package configuration
sudo systemctl enable --now crowdsec
sudo cscli bouncers delete crowdsec-firewall-bouncer 2>/dev/null || true
BOUNCER_KEY="$(sudo cscli bouncers add crowdsec-firewall-bouncer -o raw)"
sudo sed -i "s|^api_key:.*|api_key: $BOUNCER_KEY|" /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml
sudo dpkg --configure -a
sudo systemctl enable --now crowdsec-firewall-bouncer

# 4. Synchronize Hub definitions
sudo cscli hub update

# 5. Install collections
sudo cscli collections install crowdsecurity/linux
sudo cscli collections install crowdsecurity/sshd
sudo cscli collections install crowdsecurity/nginx
```

The automated script treats CrowdSec collection installation as rerun-safe. If a collection is already installed, the script logs a warning and continues instead of stopping the full setup.

#### Debian 13 Custom OpenSSH Parser Fix
Create `/etc/crowdsec/parsers/s00-raw/debian13-sshd-session.yaml`:
```yaml
onsuccess: next_stage
filter: "evt.Line.Raw contains 'sshd-session'"
name: custom/debian13-sshd-session
description: "Remap Debian 13 sshd-session to sshd before s01-parse"
nodes:
  - grok:
      pattern: '%{SYSLOGTIMESTAMP:timestamp} %{HOSTNAME:logsource} sshd-session\[%{NUMBER:pid}\]: %{GREEDYDATA:message}'
      apply_on: Line.Raw
      statics:
        - parsed: program
          value: "sshd"
        - parsed: pid
          expression: "evt.Parsed.pid"
        - parsed: message
          expression: "evt.Parsed.message"
        - parsed: source
          expression: "evt.Parsed.logsource"
```

Configure `/etc/crowdsec/acquis.yaml` to parse logs:
```yaml
---
filenames:
  - /var/log/nginx/*.log
labels:
  type: nginx
---
filenames:
  - /var/log/auth.log
  - /var/log/syslog
labels:
  type: syslog
---
source: journalctl
journalctl_filter:
  - "_SYSTEMD_UNIT=ssh.service"
labels:
  type: syslog
---
filenames:
  - /var/log/apache2/*.log
labels:
  type: apache2
```
*Register console (optional): `sudo cscli console enroll YOUR_ENROLLMENT_KEY`*
*Restart CrowdSec: `sudo systemctl restart crowdsec`*

### Step 8: Kernel Hardening & sysctl
Create `/etc/sysctl.d/99-hardening.conf` and paste the parameters in the kernel section of the setup script. Apply with `sudo sysctl --system`. The script leaves IPv6 enabled by default; the IPv6 disable lines are included as comments and should only be uncommented if you intentionally do not need IPv6.

Disable unused modules in `/etc/modprobe.d/blacklist-rare.conf`:
```
install usb-storage /bin/false
install firewire-ohci /bin/false
install dccp /bin/false
install sctp /bin/false
install rds /bin/false
install tipc /bin/false
```
Configure `auditd` rules in `/etc/audit/rules.d/hardening.rules` to monitor high-risk system files:
```
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/sudoers -p wa -k sudoers
-w /etc/ssh/sshd_config -p wa -k sshd_config
```

The automated hardening target is a Lynis hardening index of `83+`. To support that target, Phase 2 also enables AppArmor, security-only unattended upgrades, cron, auditd, sysstat, debsums, rkhunter, PAM password-quality rules, secure login umask, and core dump restrictions. The final Lynis step parses `/var/log/lynis-report.dat` and prints whether the score met the `83+` target.

Unattended upgrades are intentionally restricted to Debian security updates only via `/etc/apt/apt.conf.d/50unattended-upgrades`; normal package upgrades stay manual.

The script also guards cron permission hardening for minimal Debian images, so missing optional cron paths do not stop the setup.

### Step 9: Nginx Web Server Setup
Nginx is installed with a simple default site and a local health endpoint:
```bash
sudo apt install -y nginx
sudo nano /etc/nginx/sites-available/default
sudo nginx -t
sudo systemctl enable --now nginx
sudo systemctl reload nginx
curl http://127.0.0.1/health
```

The automated default site serves `/var/www/html/index.html`, listens on port `80`, and responds with `ok` at `/health`.

If a previous run stopped with `server_tokens directive is duplicate in /etc/nginx/conf.d/hardening.conf`, remove the legacy generated snippet and rerun the updated script:
```bash
sudo rm -f /etc/nginx/conf.d/hardening.conf
sudo nginx -t
cd ~
sudo ./setup.sh
```

The current script avoids this by placing `server_tokens off;` inside the generated default server block instead of creating a duplicate global `conf.d` file.

### Step 10: Docker Engine Setup
Docker Engine is installed and configured for future application stacks:
```bash
# Add Docker's official Debian repository first
sudo apt install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
```

The automated script also generates a GitHub deploy key at `~/.ssh/github`, writes a matching `~/.ssh/config`, prints the public key for GitHub, asks whether you added it, and can test SSH authentication with GitHub.

If the selected admin user was created outside `bootstrap.sh`, Phase 2 creates `~/.ssh` with safe ownership and permissions before generating the GitHub key.

---

## 4. Daily Operations & Diagnostics

### 📊 Health Check Utility
Run the custom health monitoring tool to inspect RAM/swap, storage, Docker containers, Nginx health, Lynis score, and CrowdSec active bans:
```bash
~/check-health.sh
```

Manual Lynis score check:
```bash
sudo lynis audit system --quick
sudo awk -F= '/^hardening_index=/ {print "Hardening index: " $2 "/100"}' /var/log/lynis-report.dat
```

### 🔁 Post-Setup Reboot
If the setup upgraded the kernel or Lynis reports `Reboot of system is most likely needed`, reboot once after Phase 2 completes:
```bash
sudo reboot
```

Reconnect through Tailscale after the server returns:
```bash
ssh -p 2626 YOUR_ADMIN_USER@YOUR_TAILSCALE_IP
```

Verify the new kernel and health status:
```bash
uname -r
~/check-health.sh
```

If reconnecting after reboot returns `Connection refused`, use the Hetzner console and remove any old Tailscale-bound `ListenAddress` line:
```bash
sudo sed -i '/^[[:space:]]*ListenAddress[[:space:]]/d' /etc/ssh/sshd_config
sudo sshd -t
sudo systemctl restart ssh
sudo systemctl restart tailscaled
```

Then reconnect with `ssh -p 2626 YOUR_ADMIN_USER@YOUR_TAILSCALE_IP`.

### 🔐 GitHub Deployment Key
The Phase 2 script creates `~/.ssh/github` and prints `~/.ssh/github.pub`. Add that public key to GitHub as a deploy key or account key, depending on your workflow. When prompted, type `yes` after adding the key and the script will run an SSH auth test against GitHub.

Manual test:
```bash
ssh -T git@github.com
```
GitHub normally returns a success message and then says shell access is not provided; that is expected.

### 📈 Useful CrowdSec Commands
```bash
sudo cscli decisions list                            # View active ip bans
sudo cscli bouncers list                             # View active nftables bouncers
sudo cscli metrics                                   # View logging parser metrics
sudo cscli decisions add --ip 1.2.3.4 --reason "manual" --duration 24h   # Manually ban an IP
sudo cscli decisions delete --ip 1.2.3.4             # Unban an IP manually
```

---

## 5. Emergency Recovery & Disaster Actions

If you are locked out of your server or cannot connect over Tailscale:
1. Log in to [console.hetzner.cloud](https://console.hetzner.cloud).
2. Select your server resources and boot the **Emergency Console** terminal.
3. Authenticate using your admin user credentials and switch to superuser mode: `sudo su -`.
4. Perform troubleshooting actions:
   * **Temporarily Disable UFW**: `ufw disable`
   * **Inspect VPN Details**: `tailscale status` or restart it: `systemctl restart tailscaled`
   * **Fix reboot-time SSH refusal**: `sed -i '/^[[:space:]]*ListenAddress[[:space:]]/d' /etc/ssh/sshd_config && sshd -t && systemctl restart ssh`
   * **Reset SSH Rules**: Copy the backup configuration back: `cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config && systemctl restart ssh`. This restores the previous SSH configuration, which is commonly Port 22 on public interfaces for a fresh server.
   * **After recovery**: Re-run Phase 2 only after confirming Tailscale is healthy with `tailscale status` and `tailscale ip -4`.
