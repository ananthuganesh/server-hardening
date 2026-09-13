# Debian 13 (Trixie) — Semi-Automated Production Server Hardening Suite

> ⚠️ **READ BEFORE STARTING**
> Steps are ordered to prevent lockouts. Never close an active SSH session until you verify the new connection works. Keep your cloud provider's web/emergency console open as a fallback at all times.

This directory contains a semi-automated, secure production server hardening suite designed to transform a fresh Debian 13 (Trixie) server into a highly secure, hardened environment in two logical phases with robust interactive checks. It is provider-neutral and works on any VPS or cloud instance running Debian.

By running these scripts, you avoid copy-paste errors, automate complex kernel and security configurations, configure RAM-based swap, set up packet filtering, configure threat intelligence via **CrowdSec**, harden SSH down to modern-only cryptography, install **Caddy** with automatic HTTPS and a clean default site, keep every package **updated automatically** in a nightly window, and install **Docker** with its published ports kept behind the firewall, guarded by interactive SSH lockout verification checks.

**Operating system:** Debian only. Both scripts refuse to run on other distributions; Debian releases other than 13 run only after a confirmation prompt.

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
   * [Cloud Provider Firewall](#step-6-cloud-provider-firewall)
   * [System IPS (Official CrowdSec Version)](#step-7-crowdsec-intrusion-prevention-system)
   * [Kernel & Auditing Controls (auditd)](#step-8-kernel-hardening--sysctl)
   * [Caddy Web Server Setup](#step-9-caddy-web-server-setup)
   * [Docker Engine Setup](#step-10-docker-engine-setup)
4. [🛠️ Daily Operations & Diagnostics](#4-daily-operations--diagnostics)
5. [🚑 Emergency Recovery & Disaster Actions](#5-emergency-recovery--disaster-actions)

---

## 1. Architecture & Firewall Layers

The server operates a multi-layered security grid, sealing all administrative assets behind an encrypted Tailscale tunnel and exposing only essential public web ports (80/443).

```
Internet
   │
   ├─ Cloud Provider Firewall    ← Layer 1: network level (provider panel / security group)
   │   ├─ TCP 80/443, UDP 443 → allowed from anywhere
   │   ├─ no SSH rule (SSH travels inside Tailscale)
   │   └─ all else   → dropped before reaching the server
   │
   ├─ UFW Firewall               ← Layer 2: OS level (automatically configured)
   │   ├─ default deny incoming
   │   ├─ allow 80/tcp, 443/tcp, 443/udp (HTTP/3)
   │   └─ allow SSH_PORT (default 2743) on tailscale0 only
   │
   ├─ CrowdSec IPS               ← Layer 3: threat intelligence (installed & tuned)
   │   ├─ OpenSSH Trixie custom sshd-session parser, Caddy access log
   │   ├─ Tailscale addresses whitelisted (no self-lockout)
   │   └─ nftables bouncer enforces active bans
   │
   ├─ Caddy Web Server           ← Layer 4: automatic HTTPS, HTTP/3, default site
   │   ├─ your sites in /etc/caddy/sites/*.caddy
   │   ├─ serves /var/www/html on port 80
   │   └─ exposes /health for local checks
   │
   └─ Docker Engine              ← Layer 5: ready for future containers
       ├─ published ports bind to 127.0.0.1 by default
       └─ DOCKER-USER rules stop published ports bypassing UFW

Tailscale VPN (100.x.x.x)
   ├─ SSH :SSH_PORT  → admin access (selected admin user, key only, modern ciphers)
   └─ Tailscale SSH :22 → emergency path, non-root users only (tailnet policy)

Nightly 03:30 → automatic updates (Debian + Tailscale, Docker, CrowdSec, Caddy)
```

---

## 2. ⚡ Quick Start: Semi-Automated Script Setup (Recommended)

To run the semi-automated hardening cycle, use the provided scripts (`bootstrap.sh` and `setup.sh`) located in this directory. Phase 1 creates the administrative user and places Phase 2 in that user's home directory. Phase 2 performs the system hardening, with interactive checkpoints before the lockout-sensitive steps continue.

### Step A: Open Your Provider's Emergency Console
1. Log in to your cloud provider's dashboard.
2. Open the server's browser-based console (often called web console, VNC console, serial console, or browser terminal). Keep it open as an emergency backup; it works even when SSH is broken.
3. **Confirm the console actually gives you a login prompt.** Some providers require enabling the serial console in account or instance settings first. After Phase 2, this console is your **only** way in if Tailscale ever fails.
4. Do **not** apply a restrictive provider firewall or security group yet. Keep normal public SSH reachable until Phase 2 confirms Tailscale SSH and you complete one reboot/reconnect test.

> The emergency console logs in with a password, not an SSH key. Phase 1 sets a password for the admin user, and Phase 2 refuses to continue until that user has one, because Phase 2 locks root. Save the password in your password manager: `sudo` needs it too.

### Step B: Get the Scripts onto the Server
Either upload them from your **local machine (MacBook)**:
```bash
scp bootstrap.sh setup.sh root@YOUR_SERVER_PUBLIC_IP:/root/
```
or clone this repository on the server and run the scripts from the clone.

### Step C: Execute Phase 1 — Environment Bootstrapping (Run as `root`)
SSH into your server as root via public IP and execute:
```bash
chmod +x bootstrap.sh setup.sh
./bootstrap.sh
```
Some providers disable root SSH login and give you a default sudo user instead (for example `admin` or `debian`). In that case upload the scripts to that user's home and run `sudo ./bootstrap.sh`.

* **Interactive Prompts**: Phase 1 is the only place you enter the hostname and username; Phase 2 reuses them. The script asks for:
  No names are hardcoded:
  * **Server hostname**: press Enter to keep the current one. It is applied first, so the generated .pem file and the later setup already use it. If cloud-init is present, the script writes `/etc/cloud/cloud.cfg.d/99-preserve-hostname.cfg` so the provider doesn't reset the hostname or `/etc/hosts` on reboot.
  * **Timezone**: not prompted. Always set to `Asia/Kolkata`, and the nightly update window (03:30) uses it.
  * **Administrative username**: required, with no default. Existing system accounts with a UID below 1000 are refused.
  * **Password** of at least 14 characters, matching the password policy Phase 2 installs.
  * **SSH login key**: no prompt. Login always uses an **Ed25519 .pem key generated on the server** (OpenSSH format, works with `ssh` on macOS, Linux and Windows 10+). You can't paste your own public key or choose another key type. The private key is saved as `ADMIN-HOSTNAME.pem` in the home directory of the account running the script: `/root` when run as root, or the default sudo user's home when run with `sudo`.
* **Downloading the .pem key**: the server can't push files to your computer, so the end of Phase 1 prints the download commands. They save into `~/keys/`. Run them **on your computer**. Set `-i` to the key you logged in with (for example your cloud provider's key pair), and replace `root` and `/root` with the default user and its home if you ran with `sudo`:
  ```bash
  mkdir -p ~/keys
  scp -i ~/keys/YOUR_CURRENT_LOGIN_KEY.pem root@YOUR_SERVER_PUBLIC_IP:/root/YOUR_ADMIN_USER-HOSTNAME.pem ~/keys/
  chmod 600 ~/keys/YOUR_ADMIN_USER-HOSTNAME.pem
  ssh -i ~/keys/YOUR_ADMIN_USER-HOSTNAME.pem -o IdentitiesOnly=yes YOUR_ADMIN_USER@YOUR_SERVER_PUBLIC_IP
  ```
  The script then waits: type `show` to print the key in the terminal (useful from a web console), `delete` to shred the server copy once login works, or `keep`. The key is generated without a passphrase; add one locally with `ssh-keygen -p -f ~/keys/YOUR_ADMIN_USER-HOSTNAME.pem`.
* **Reconfiguring a key later**: the previous `authorized_keys` is saved as `authorized_keys.bak.TIMESTAMP` first.
  * If the server is already hardened, the printed commands use the Tailscale IP and your SSH port.
  * If you regenerate the .pem key for the account you are logged in as, `scp` can't work, because it would need the new key. Use `show` to copy the key, and don't type `delete` until a new login succeeds.
* **Keep the root session open** until you confirm that the new `YOUR_ADMIN_USER` SSH login works from another terminal.
* **Rerun behavior**: If the admin user already exists and you choose not to reconfigure the password/key, Phase 1 still refreshes `setup.sh` in that user's home directory.
* **Adding a second admin to a hardened server**: sshd only admits the users in `AllowUsers`, so Phase 1 offers to add the new user there (validated with `sshd -t` and restored on failure). When that user later runs `sudo ./setup.sh`, the existing admins stay in `AllowUsers`; nobody is removed.
* **Public IP output**: At the end, `bootstrap.sh` asks public IP lookup services (`api.ipify.org`, then `ifconfig.me`), falls back to local route detection, and prints the real `ssh -i ~/keys/YOUR_ADMIN_USER-HOSTNAME.pem ... YOUR_ADMIN_USER@SERVER_PUBLIC_IP` command when detection succeeds. On providers that use NAT, the local-route fallback shows a private IP; use the public IP from your provider's dashboard instead.

### Step D: Execute Phase 2 — System Hardening (Run as `YOUR_ADMIN_USER`)
Open a **new terminal** on your local machine and connect as the newly created admin user:
```bash
ssh -i ~/keys/YOUR_ADMIN_USER-HOSTNAME.pem -o IdentitiesOnly=yes YOUR_ADMIN_USER@YOUR_SERVER_PUBLIC_IP
```
Execute the main configuration and security hardening suite with `sudo` from your home directory (where `bootstrap.sh` automatically copied it with correct permissions):
```bash
cd ~
sudo ./setup.sh
```

#### 💡 Safe Interactive Checkpoints in Phase 2:
Phase 2 doesn't ask for the username or hostname again. It uses the account that ran `sudo ./setup.sh` as the admin user, and the hostname and timezone set in Phase 1. It only asks for a username if it can't detect one, for example when started from a root shell.

**SSH port prompt**: Phase 2 asks which port SSH should use, reachable only over Tailscale.
* **Default:** `2743`. On a rerun, the default is the port SSH already uses, so pressing Enter never moves SSH.
* **Allowed:** 1024–65535. It refuses a port another program already uses, and the ports Caddy (2019) and CrowdSec (6060, 8080) use. Port 22 is excluded on purpose, because Tailscale SSH already answers on port 22 of the Tailscale IP.
* **Changing the port on a rerun** closes the old port's UFW rule. A rollback brings the old port back.

In the commands below, `SSH_PORT` means the port you chose.

**Pre-flight lockout checks** (before anything changes):
* The admin user must have a valid key in `~/.ssh/authorized_keys`, or Phase 2 stops. It also fixes permissions on the home directory, `~/.ssh` and `authorized_keys`, because with `StrictModes` sshd silently ignores keys when those are writable by other users.
* The admin user must have a usable password, or Phase 2 asks you to set one. Root gets locked, and the emergency console needs a password.

1. **Tailscale login**: The script asks for an optional **Tailscale auth key** (hidden input).
   * **With a key:** the server joins your tailnet with no browser step.
   * **Empty, or the key is rejected:** it runs `tailscale up --ssh --accept-dns=true --accept-routes=false` and prints a login URL to open in the browser.

   Either way it waits up to 2 minutes for activation. If Tailscale fails or times out, the script stops before touching SSH. On reruns the server is already logged in, so there's no prompt. See [Tailscale auth keys](#tailscale-auth-keys-skip-the-browser-login).
   * **Key expiry check**: Tailscale node keys expire after 180 days by default. When that happens, the server leaves the tailnet and SSH is gone. If expiry is enabled, the script stops and asks you to disable it: **Tailscale admin console → Machines → server → ⋯ → Disable key expiry**.
   * `--accept-routes=false`: if another tailnet device advertises a subnet route that overlaps this server's own network (for example a 10.x private or VPC range), accepting it would pull local traffic into Tailscale and cut the server off.
2. **UFW & SSH Verification Gate**: The script arms a 10-minute automatic rollback, moves SSH to the port you chose (see **SSH port** below), restricts that port to the Tailscale interface in UFW, and pauses.
   * **Keep your current terminal open.**
   * Open a **NEW local terminal** on your MacBook and run: `ssh -i ~/keys/YOUR_ADMIN_USER-HOSTNAME.pem -o IdentitiesOnly=yes -p SSH_PORT YOUR_ADMIN_USER@YOUR_TAILSCALE_IP`.
   * `MaxAuthTries` is 3. If your SSH agent (1Password, Secretive, `ssh-add`) holds several keys, ssh tries them all and the server refuses the login before reaching the right one. Always pass `-i` together with `-o IdentitiesOnly=yes`.
   * If it connects, enter **`yes`** to cancel the rollback timer, complete setup, and lock down root. If you answer after the 10-minute window, the rollback has already run. The script detects this and stops instead of pretending the server is hardened.
   * If it fails, enter **`no`**. The script restores your previous SSH config and disables UFW entirely to ensure you are not locked out.
   * If your session dies before you answer, the rollback timer restores the previous SSH config and disables UFW automatically after 10 minutes.
3. **CrowdSec Console Key**: The script prompts for your CrowdSec dashboard enrollment key. Paste it to register the node, or press Enter to skip.
4. **Cloud provider firewall** (last step): The script prints the exact inbound rules for your provider's firewall or security group: allow TCP 80, TCP 443 and UDP 443, and remove TCP 22. Then it asks `done`, `not` or `skip`. See [Step 6](#step-6-cloud-provider-firewall).

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
sudo timedatectl set-timezone Asia/Kolkata    # automated in bootstrap.sh (fixed, not prompted)
sudo hostnamectl set-hostname YOUR_HOSTNAME   # automated in bootstrap.sh (prompted)
sudo sed -i "s|^127\.0\.1\.1.*|127.0.1.1 YOUR_HOSTNAME|" /etc/hosts
# On cloud-init images, keep the provider from resetting it at boot:
printf 'preserve_hostname: true\nmanage_etc_hosts: false\n' | sudo tee /etc/cloud/cloud.cfg.d/99-preserve-hostname.cfg
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
sudo tailscale up --ssh --accept-dns=true --accept-routes=false
tailscale ip -4 # Retrieve your VPN IP (e.g. 100.116.117.35)
tailscale status --json | jq -r '.Self.KeyExpiry // "key expiry disabled"'
```
The automated script stops if `tailscale up` fails or if Tailscale does not become active within 2 minutes.

#### Tailscale auth keys (skip the browser login)
Every server joins your tailnet as its own device. Your Mac being logged in doesn't authorize the server, which is why a browser link appears. To skip that step, create an auth key in the **Tailscale admin console → Settings → Keys → Generate auth key**, and paste it when Phase 2 asks.

**How the script handles the key:**
* It reads the key hidden, never prints it, and never stores it. Leave the prompt empty to use the browser login.
* It passes the key as `--auth-key=file:/root/.tailscale-authkey.XXXXXX`, a root-only temporary file shredded right after login. The key never appears in the process list, shell history or the auditd log of root commands.
* If Tailscale rejects the key (expired, already used, revoked), it falls back to the browser login.

**Recommended key settings:**
| Setting | Recommendation |
|---|---|
| Reusable | Only if you set up several servers in a row; revoke it afterwards. A one-off key is safest. |
| Expiration | Short (1–7 days). This is how long the *key* can be used, not the server's own key expiry. |
| Pre-approved | On, if your tailnet requires device approval; otherwise the server waits for approval in the console. |
| Tags | Optional. Tagged servers get **no key expiry**, but they no longer match the default Tailscale SSH rule (`"dst": ["autogroup:self"]`). The script warns about this. Add an `ssh` rule with `"dst": ["tag:server"]` and `"users": ["autogroup:nonroot"]`, or the emergency Tailscale SSH path is gone. |

> An auth key lets anyone who has it add devices to your tailnet. Treat it like a password, never commit it, and revoke it once your servers are set up.

**Disable key expiry for every server** in the Tailscale admin console. SSH is reachable only through Tailscale, so an expired node key means a lockout until you use the emergency console. `~/check-health.sh` reports the expiry date.

#### Tailscale SSH: emergency path, non-root only
`--ssh` also enables **Tailscale SSH** on port 22 of the Tailscale IP. Tailscale SSH is a separate SSH server run by `tailscaled`, and it is authorized by your tailnet access policy, not by `sshd_config`. It is kept on purpose as an emergency way in if sshd ever breaks. However, it doesn't follow `AllowUsers`, key-only login or the root lock, so **the tailnet policy must not allow root**. This can't be enforced from the server; set it once in the **Tailscale admin console → Access controls**.

The default policy includes `"root"` in its `ssh` rule. Remove it so the rule looks like this:
```json
"ssh": [
  {
    "action": "check",
    "src":    ["autogroup:member"],
    "dst":    ["autogroup:self"],
    "users":  ["autogroup:nonroot"]
  }
]
```
* `autogroup:nonroot` allows any local user except root. To be stricter, list only the admin user: `"users": ["YOUR_ADMIN_USER"]`.
* `check` asks you to re-authenticate in the browser periodically. Use `"accept"` to skip that.
* If your servers use a tag such as `tag:server`, use `"dst": ["tag:server"]` and a `src` like `["autogroup:admin"]`.

Emergency login: `ssh YOUR_ADMIN_USER@YOUR_TAILSCALE_IP` (port 22, no key needed; Tailscale authenticates you), then `sudo` with the admin password.

### Step 4: SSH Hardening
Edit `/etc/ssh/sshd_config`:
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
AllowUsers YOUR_ADMIN_USER
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
*Validate config with `sudo sshd -t` and restart with `sudo systemctl restart ssh`.*

SSH intentionally does **not** use `ListenAddress YOUR_TAILSCALE_IP`; at boot, SSH can start before `tailscale0` has its IP address. UFW enforces the Tailscale-only restriction with an interface-scoped rule instead.

#### Cryptography hardening (automatic)
* **Algorithms**: Only modern key exchange (post-quantum hybrids, Curve25519, 3072+ bit DH), AEAD/CTR ciphers, and encrypt-then-MAC MACs are allowed. CBC ciphers, SHA-1 and weak DH groups are rejected. The script checks each algorithm against `ssh -Q` and keeps only the ones the installed OpenSSH supports, so the config never fails validation after an OpenSSH upgrade or on an older Debian release.
* **Host keys**: Only Ed25519 and RSA host keys are offered. `ssh-keygen -A` creates any missing keys, and an RSA host key under 3072 bits is regenerated at 4096 bits.
* **DH moduli**: Entries under 3072 bits are removed from `/etc/ssh/moduli` (original saved as `/etc/ssh/moduli.bak`).
* **Client keys**: User key types are not restricted, so existing `ssh-ed25519`, `ssh-rsa` (SHA-2 signatures), `ecdsa-*` and hardware `sk-*` keys keep working.
* **Old clients**: Clients that only support CBC ciphers or SHA-1 key exchange (very old PuTTY or embedded SSH libraries) can no longer connect. Update them rather than weakening the server.

Cloud images often ship drop-ins in `/etc/ssh/sshd_config.d/` (for example one that sets `PasswordAuthentication yes`). The hardened settings come before the `Include` line, and sshd uses the first value it reads, so they win. After writing the config, the script also checks the effective values with `sshd -T`. If a drop-in still overrides the port, root login, password login, or public-key login, it rolls back instead of continuing.

Before changing SSH/UFW, the automated script snapshots the live state and schedules an emergency rollback with `systemd-run`. If the new SSH connection is not confirmed within 10 minutes, or you answer `no`, the rollback restores the state **from just before this run**:
* **SSH config**: `/etc/ssh/sshd_config.pre-run` is copied back.
* **First run** (UFW was inactive): UFW is disabled, so the original public SSH works again.
* **Rerun on a hardened server** (UFW was active): the previous UFW rules come back from `/root/ufw-pre-run/`, so the server stays Tailscale-only instead of reopening port 22 to the internet.

`/etc/ssh/sshd_config.bak` is the untouched original from the very first run, kept for manual recovery.

### Step 5: UFW Firewall
```bash
sudo apt install ufw -y
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw default deny forward

# Allow public web traffic
sudo ufw allow 80/tcp comment 'HTTP'
sudo ufw allow 443/tcp comment 'HTTPS'
sudo ufw allow 443/udp comment 'HTTP/3 (Caddy)'

# Allow SSH only on Tailscale
sudo ufw allow in on tailscale0 to any port SSH_PORT proto tcp comment 'SSH via Tailscale only'
sudo ufw enable
```

### Step 6: Cloud Provider Firewall
Most providers offer a network firewall in front of the server (called a firewall, security group, or network ACL in the dashboard). If yours does, define these rules there:
* **Inbound HTTP**: TCP `80` from `0.0.0.0/0` and `::/0`
* **Inbound HTTPS**: TCP `443` and UDP `443` (HTTP/3) from `0.0.0.0/0` and `::/0`
* **Inbound Tailscale (optional)**: UDP `41641` from `0.0.0.0/0` and `::/0`. This allows direct peer connections; without it Tailscale still works through relays, just slower.
* **No SSH rule.** SSH traffic travels inside the encrypted Tailscale tunnel, so the provider firewall never sees the SSH port. Don't open 22 or your SSH port publicly.
* **Outbound**: Allow all outbound traffic. Tailscale and CrowdSec need it, and so do apt and Docker.

**Phase 2 prompts for this at the end.** It prints these rules, using your SSH port, then asks `Provider firewall configured? (done/not/skip)`:

| Answer | Meaning | Afterwards |
|---|---|---|
| `done` | You set the rules in the provider panel | Not asked again on reruns |
| `not` | Not set yet | `~/check-health.sh` reminds you until you mark it: `echo done \| sudo tee /var/lib/server-setup/provider-firewall` |
| `skip` | Your provider has no network firewall | Not asked again; UFW enforces the same rules on the server |

The answer is saved in `/var/lib/server-setup/provider-firewall`. It's asked only at the end, after SSH over Tailscale was verified, so removing public port 22 at that point doesn't lock you out. Test a reboot soon after. If your provider has no network firewall, UFW (Step 5) still enforces the same policy on the server.

> Once public port 22 is closed, the automatic SSH rollback (which restores the old port-22 config) is reachable only over Tailscale or the emergency console. Test the console first.

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
sudo cscli collections install crowdsecurity/caddy
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

#### Never ban Tailscale addresses (prevents self-lockout)
Admin SSH arrives from Tailscale addresses (`100.64.0.0/10`), and CrowdSec's default whitelist doesn't cover them. A few failed key attempts from your laptop (for example an agent offering the wrong keys) would ban your Tailscale IP. The nftables bouncer blocks a banned IP on every interface, including `tailscale0`, so you would be locked out. Create `/etc/crowdsec/parsers/s02-enrich/tailscale-whitelist.yaml`:
```yaml
name: custom/tailscale-whitelist
description: "Never ban Tailscale addresses; admin SSH arrives from them"
whitelist:
  reason: "Tailscale admin network"
  cidr:
    - "100.64.0.0/10"
    - "fd7a:115c:a1e0::/48"
```
The script also removes any existing bans on individual Tailscale IPs (`cscli decisions delete --range 100.64.0.0/10 --contained`; without `--contained`, only a ban on the whole range would match). It also enables `crowdsec-hubupdate.timer`, so parsers and scenarios update daily.

Configure `/etc/crowdsec/acquis.yaml` to parse logs. sshd events are read **once**, from `/var/log/auth.log`. An additional `journalctl` source for `ssh.service` would count every failed login twice and ban twice as fast.
```yaml
---
filenames:
  - /var/log/caddy/access.log
labels:
  type: caddy
---
filenames:
  - /var/log/auth.log
  - /var/log/syslog
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

IP forwarding is deliberately **not** set to 0. Docker needs forwarding, and packages run `sysctl --system` during upgrades, so `ip_forward = 0` would silently break every container later. Forwarded traffic is still filtered by UFW (`default deny forward`) and the Docker firewall rules.

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
-w /home/YOUR_ADMIN_USER/.ssh/authorized_keys -p wa -k ssh_keys
-a always,exit -F arch=b32 -S execve -F euid=0 -k root_commands   # x86_64 only
```
The `arch=b32` rule matters: without it, a root process using 32-bit system calls would slip past the `root_commands` logging. Search events with `sudo ausearch -k root_commands -i` (or `-k ssh_keys`, `-k sudoers`, and so on).

**Locked root vs. boot problems**: with root locked, systemd's emergency/rescue shell (after a bad `/etc/fstab` line or a failed mount) normally refuses to open, leaving the provider console useless. Phase 2 adds `SYSTEMD_SULOGIN_FORCE=1` to `emergency.service` and `rescue.service`, so that shell opens on the console. The console is only reachable by someone already logged into your provider account.

**Time sync**: if no NTP service is active, Phase 2 installs `systemd-timesyncd` and enables it. HTTPS certificates, Tailscale check mode and log timestamps need correct time.

The automated hardening target is a Lynis hardening index of `83+`. To support that target, Phase 2 also enables AppArmor, automatic updates, cron, auditd, sysstat, debsums, rkhunter, PAM password-quality rules, secure login umask, and core dump restrictions. The final Lynis step parses `/var/log/lynis-report.dat` and prints whether the score met the `83+` target.

#### Automatic updates (safe nightly window)
All packages update automatically every night. Instead of a raw cron job, this uses Debian's `unattended-upgrades` on its systemd timers, the built-in scheduler for apt jobs. A plain cron job running `apt upgrade` can collide with a manual apt run, and it can leave dpkg half-configured after a crash or reboot. `unattended-upgrades` takes the dpkg lock, repairs interrupted runs, installs in small steps, and logs everything.

| Setting | Value |
|---|---|
| What updates | Debian stable, point releases and security updates, plus the Tailscale, Docker, CrowdSec and Caddy repositories (`/etc/apt/apt.conf.d/50unattended-upgrades`) |
| When | Package lists refresh at 02:30, and updates install at **03:30 server time**, with a small random delay. A missed window is skipped, not run after a daytime boot. |
| Config files | `--force-confold`: locally modified configs (`sshd_config`, UFW rules, Caddyfile) are never replaced by package defaults, so an upgrade can't reset SSH to port 22. |
| Services | `needrestart` restarts services still using old libraries, so security fixes take effect. SSH sessions survive, and Docker containers keep running (`live-restore`). |
| Reboots | **Manual.** Kernel updates need a reboot, and `~/check-health.sh` reports when one is pending. To reboot automatically, set `Unattended-Upgrade::Automatic-Reboot "true";` and `Unattended-Upgrade::Automatic-Reboot-Time "04:30";` |

At the end of Phase 2 the script runs `unattended-upgrade --dry-run` to confirm the configuration works. Useful commands:
```bash
systemctl list-timers apt-daily-upgrade.timer          # next scheduled run
sudo unattended-upgrade --dry-run --debug              # what would be upgraded now
sudo tail -n 50 /var/log/unattended-upgrades/unattended-upgrades.log
```

The script also guards cron permission hardening for minimal Debian images, so missing optional cron paths do not stop the setup.

### Step 9: Caddy Web Server Setup
[Caddy](https://caddyserver.com) is installed from its official repository. It gets and renews HTTPS certificates automatically for any real domain name, and it serves HTTP/3 over UDP 443.
```bash
sudo apt install -y curl gnupg
curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg --yes
echo "deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main" | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update && sudo apt install -y caddy
curl http://127.0.0.1/health
```

**Layout**:
* `/etc/caddy/Caddyfile` is **managed by the script and overwritten on reruns**. It holds:
  * the shared `site_defaults` snippet: compression, security headers including HSTS (`max-age` one year, no `includeSubDomains`), no `Server` header, a JSON access log, and 404 for dotfiles such as `.git`/`.env`;
  * a default `:80` site serving `/var/www/html` with `ok` at `/health`;
  * `import /etc/caddy/sites/*.caddy`.
* `/etc/caddy/sites/*.caddy` holds **your sites**, one file per site. The script never overwrites these. The directory is `root:caddy` with setgid, so files created with the `027` umask stay readable by Caddy. `README.caddy` there contains examples.
* `/var/log/caddy/access.log` is the JSON access log, read by CrowdSec (`crowdsecurity/caddy` collection).
* `/etc/sysctl.d/60-caddy-quic.conf` raises the UDP buffers that HTTP/3 needs.

Add a site (for example a Docker container published on `127.0.0.1:3000`; avoid 8080, which CrowdSec uses):
```bash
sudo tee /etc/caddy/sites/example.com.caddy >/dev/null <<'EOF'
example.com {
	import site_defaults
	reverse_proxy 127.0.0.1:3000
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile && sudo systemctl reload caddy
```
Point the domain's DNS at the server first; Caddy then gets the certificate on its own.

The script validates the Caddyfile (as the `caddy` user) before installing it. If a site file is broken, it keeps the previous Caddyfile instead of taking the web server down. A deployed `/var/www/html/index.html` is never replaced; only the script's own default page is.

**Migrating from Nginx** (servers set up by earlier versions of this script): Phase 2 stops and disables Nginx so Caddy can use ports 80/443. The `nginx` package and `/etc/nginx` are kept, so remove them later with `sudo apt purge nginx`. If Nginx serves sites other than the script's default, Phase 2 lists them and asks before switching. Answer `N` to keep Nginx, move the sites to `/etc/caddy/sites/`, then rerun.

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

#### Hardened daemon configuration (automatic)
`/etc/docker/daemon.json` (the original is saved as `daemon.json.bak`):
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
* `ip: 127.0.0.1`: `-p 3000:80` publishes on localhost only, so Caddy can reverse-proxy to the container without exposing it. To publish publicly on purpose, give the host IP explicitly: `-p 0.0.0.0:3000:80`. **Don't use host port 8080**: CrowdSec's local API listens on `127.0.0.1:8080`, and taking that port disables CrowdSec bans.
* `icc: false`: containers on the default bridge cannot talk to each other. Containers on the same user-defined network (for example a Compose project) still can.
* `no-new-privileges: true`: setuid binaries inside containers cannot gain extra privileges.
* `live-restore: true`: containers keep running while the Docker daemon restarts or upgrades. This setting is not compatible with Docker Swarm mode.

The script validates the file with `dockerd --validate` and restores the previous config if Docker fails to restart.

> **The `docker` group is root-equivalent.** The admin user is added to it, and anyone in it can run `docker run -v /:/host ...` and get full root access without a sudo password. Protect the admin SSH key accordingly (a passphrase, or a hardware `sk-` key), or remove the user from the group with `sudo gpasswd -d YOUR_ADMIN_USER docker` and use `sudo docker`.

#### Docker ports no longer bypass UFW (automatic)
By default, Docker writes its own iptables rules that run **before** UFW. That means a port published with `-p 0.0.0.0:...` is reachable from the internet even though UFW says `deny`. The script appends a `# BEGIN UFW AND DOCKER` block to `/etc/ufw/after.rules` (based on [ufw-docker](https://github.com/chaifeng/ufw-docker)). That block puts traffic to containers back under UFW:
* New inbound connections from the public internet to containers are dropped and logged with the prefix `[UFW DOCKER BLOCK]`.
* Container outbound traffic, replies, private networks (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`) and your Tailscale network are still allowed.
* To expose a container port publicly, allow it as a routed rule using the **container** port:
  ```bash
  sudo ufw route allow proto tcp from any to any port 80
  ```

If UFW rejects the rules, the script restores `/etc/ufw/after.rules.pre-docker.bak` and reloads.

Phase 2 does not create any GitHub key. Instead it installs `~/github-deploy-key.sh`, which creates a separate deploy key for each project (see [GitHub Deploy Keys](#-github-deploy-keys-one-per-project)).

---

## 4. Daily Operations & Diagnostics

### 📊 Health Check Utility
Run the custom health monitoring tool to inspect RAM/swap, storage, Docker containers, Caddy health, automatic update runs, Tailscale connection and key expiry, Lynis score, and CrowdSec active bans:
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
ssh -i ~/keys/YOUR_ADMIN_USER-HOSTNAME.pem -o IdentitiesOnly=yes -p SSH_PORT YOUR_ADMIN_USER@YOUR_TAILSCALE_IP
```

Verify the new kernel and health status:
```bash
uname -r
~/check-health.sh
```

If reconnecting after reboot returns `Connection refused`, use your provider's emergency console and remove any old Tailscale-bound `ListenAddress` line:
```bash
sudo sed -i '/^[[:space:]]*ListenAddress[[:space:]]/d' /etc/ssh/sshd_config
sudo sshd -t
sudo systemctl restart ssh
sudo systemctl restart tailscaled
```

Then reconnect with `ssh -i ~/keys/YOUR_ADMIN_USER-HOSTNAME.pem -o IdentitiesOnly=yes -p SSH_PORT YOUR_ADMIN_USER@YOUR_TAILSCALE_IP`.

### 🔐 GitHub Deploy Keys (one per project)
GitHub lets you add a deploy key to **one repository only**, so every project deployed on the server needs its own key. Run the helper as the admin user (not with `sudo`) when you deploy a project:
```bash
~/github-deploy-key.sh OWNER/REPO
```
The helper:
1. Creates `~/.ssh/deploy_OWNER_REPO` (Ed25519, no passphrase so deployments can run unattended), or reuses it if it already exists.
2. Adds a `Host github-OWNER-REPO` alias to `~/.ssh/config` that uses only that key.
3. Adds GitHub's host key to `~/.ssh/known_hosts`, but only if it matches GitHub's published Ed25519 fingerprint.
4. Prints the public key. Add it on GitHub under **Repo → Settings → Deploy keys → Add deploy key**, and leave **Allow write access** unchecked unless the server must push.
5. Tests authentication after you press Enter, then prints the clone URL.

Use the alias instead of `github.com` in the Git URL:
```bash
git clone git@github-OWNER-REPO:OWNER/REPO.git
git remote set-url origin git@github-OWNER-REPO:OWNER/REPO.git   # existing checkout
ssh -T git@github-OWNER-REPO                                     # manual test
```
GitHub normally returns a success message and then says shell access is not provided; that is expected.

To revoke a project's access, delete its deploy key on GitHub, remove `~/.ssh/deploy_OWNER_REPO*`, and remove its `Host` block from `~/.ssh/config`.

Servers set up with an earlier version of this script have a shared `~/.ssh/github` key, a `Host github.com` block in `~/.ssh/config`, and ssh-agent lines in `~/.bashrc`. Phase 2 warns about these but leaves them in place. Remove them once every project has its own deploy key.

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
1. Log in to your cloud provider's dashboard.
2. Open the server's web, VNC, or serial console.
3. Authenticate using your admin user password and switch to superuser mode: `sudo su -`.
4. Perform troubleshooting actions:
   * **Temporarily Disable UFW**: `ufw disable`
   * **Inspect VPN Details**: `tailscale status` or restart it: `systemctl restart tailscaled`
   * **Tailscale key expired** (`tailscale status` shows it logged out or expired): run `tailscale up --ssh --accept-dns=true --accept-routes=false`, open the login URL, then disable key expiry for the machine in the admin console.
   * **Banned by CrowdSec** (connection times out from one IP only): `cscli decisions list`, then `cscli decisions delete --ip YOUR_IP`.
   * **Fix reboot-time SSH refusal**: `sed -i '/^[[:space:]]*ListenAddress[[:space:]]/d' /etc/ssh/sshd_config && sshd -t && systemctl restart ssh`
   * **Reset SSH Rules**: `cp /etc/ssh/sshd_config.pre-run /etc/ssh/sshd_config && systemctl restart ssh` restores the config from before the last setup run. `sshd_config.bak` is the original distro config (usually port 22 on all interfaces).
   * **Boot stuck in emergency mode** (bad `/etc/fstab`, failed mount): the console opens a root shell directly (`SYSTEMD_SULOGIN_FORCE=1`). Fix the problem, then run `systemctl default` or reboot.
   * **Lost the .pem private key**: It cannot be recovered. From the console (`sudo su -`), rerun `bootstrap.sh`, answer `y` to reconfigure the user, and a new .pem key is generated. Copy it with `show`, because `scp` needs a working login.
   * **Old SSH client rejected** (`no matching key exchange method` / `no matching cipher`): update the client. For a temporary fix, restore `/etc/ssh/sshd_config.bak` as below.
   * **Undo the Docker firewall rules**: delete the `# BEGIN UFW AND DOCKER` … `# END UFW AND DOCKER` block from `/etc/ufw/after.rules`, then run `ufw reload`.
   * **After recovery**: Re-run Phase 2 only after confirming Tailscale is healthy with `tailscale status` and `tailscale ip -4`.
