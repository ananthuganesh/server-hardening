# Debian 13 Server Setup & Hardening

Two interactive Bash scripts that turn a fresh **Debian 13 (Trixie)** server into a hardened, production-ready host. They take you from a new server to this, with safety checks at every step that could lock you out:
- SSH reachable only through a VPN: Tailscale, or your own self-hosted WireGuard;
- a firewall, intrusion prevention, kernel and audit hardening;
- automatic updates;
- the Caddy web server, and Docker or rootless Podman.

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
- SSH only over your **admin VPN**, on a port you choose: **Tailscale** (default) or **self-hosted WireGuard**. Key-only login with an **Ed25519 key generated on the server**, and root login disabled.
- With Tailscale, **Tailscale SSH** as a separate emergency login path, limited to non-root users by your tailnet policy.
- Optional **full tunnel**, so the server also works as your personal VPN gateway for browsing.
- A **10-minute automatic rollback** while you test the new SSH connection, so a mistake can't lock you out.

**Network protection**
- A **UFW** firewall: deny by default, with only web ports public.
- **CrowdSec** intrusion prevention with an nftables bouncer, reading SSH and web logs.
- **Container ports can't bypass the firewall**: with Docker, containers publish on `127.0.0.1` by default and extra rules guard anything published publicly; rootless Podman is covered by UFW on its own.

**System hardening**
- Modern-only SSH cryptography, filtered to what the installed OpenSSH supports.
- Kernel `sysctl` hardening, unused kernel modules disabled, and `auditd` rules.
- AppArmor, password quality rules, disabled core dumps, and a secure umask.
- A root account that stays locked, but an emergency boot shell that still works from the provider console.

**Operations**
- **Automatic nightly updates** for Debian, Tailscale, CrowdSec, Caddy and Docker (Podman updates come with Debian), with safeguards so configs are never overwritten.
- The **Caddy** web server with automatic HTTPS and HTTP/3, plus a separate folder for your own sites.
- **Docker Engine or rootless Podman**, your choice at setup time, both with hardened settings.
- A **GitHub deploy key helper** that creates one key per repository.
- A **health check script** and a **Lynis** security audit (target score 83+; a test run scored 85).

---

## How it works

Setup runs in two phases, both **on the server**:

| Phase | Script | Runs as | What it does |
|---|---|---|---|
| 1 | `bootstrap.sh` | `root`, or `sudo` from the provider's default user | Sets the hostname and timezone, creates your admin user, generates the SSH login key, and copies `setup.sh` into the admin user's home |
| 2 | `setup.sh` | The new admin user, with `sudo` | Hardens the whole system: Tailscale, SSH, firewall, CrowdSec, kernel, updates, Caddy and your container engine |

The finished server is protected in layers:

```
Internet
   │
   ├─ Provider firewall / security group   (you set this; the script prints the rules)
   │    ├─ TCP 80, TCP 443, UDP 443  → allowed
   │    └─ everything else, including SSH → blocked
   │
   ├─ UFW firewall (on the server)
   │    ├─ deny incoming by default
   │    ├─ allow 80/tcp, 443/tcp, 443/udp
   │    └─ allow the SSH port only on the tailscale0 interface
   │
   ├─ CrowdSec    bans attackers found in SSH and Caddy logs (Tailscale IPs are never banned)
   ├─ Caddy       automatic HTTPS, HTTP/3, your sites in /etc/caddy/sites/
   └─ Containers  Docker (published on 127.0.0.1 by default) or rootless Podman

Admin VPN (Tailscale 100.x.x.x, or WireGuard 10.66.66.0/24)
   ├─ SSH on your chosen port  → admin login with the .pem key
   └─ Tailscale SSH on port 22 → emergency login, non-root users only (Tailscale only)

Every night at 03:30 → automatic updates
```

---

## Requirements

- A **fresh Debian 13 server** from any provider. The scripts refuse other operating systems, and other Debian releases need a confirmation.
- **Root access**, or a default user with `sudo`.
- For the **Tailscale** VPN: an account, with Tailscale installed and logged in **on your own computer**.
- For **self-hosted WireGuard**: a WireGuard client on your computer, and the ability to open one **public UDP port** for the server.
- A **working emergency console** at your provider (web, VNC or serial console). Some providers require you to enable it first.
- **Optional:**
  - a [Tailscale auth key](#tailscale-auth-keys), to skip the browser login;
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
| `TAILSCALE_IP` | The server's Tailscale IP (`100.x.x.x`), shown during Phase 2 |
| `SSH_PORT` | The SSH port you choose in Phase 2 (default `2743`) |
| `LOGIN_KEY` | The key you use to log in to the fresh server today, for example your provider's key pair |

### 1. Prepare

1. Open your provider's **emergency console** and confirm it shows a login prompt. After setup, it's your only way in if Tailscale ever fails.
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

The script then generates an **Ed25519 login key** named `ADMIN-HOST.pem` and prints the commands to download it. **Run these on your computer**, not on the server:

```bash
mkdir -p ~/keys
```
```bash
scp -i LOGIN_KEY root@SERVER_IP:/root/ADMIN-HOST.pem ~/keys/
```
```bash
chmod 600 ~/keys/ADMIN-HOST.pem
```

If you ran the script with `sudo` as the provider's default user, download from that user's home instead, for example `admin@SERVER_IP:/home/admin/ADMIN-HOST.pem`. The script prints the exact path.

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
| SSH port | Press Enter for `2743`, or type another port (1024–65535) |
| Container engine | Press Enter for `docker`, or type `podman` for rootless containers ([comparison](#containers-docker-or-podman)) |
| Admin VPN | Press Enter for `tailscale`, or type `wireguard` for a self-hosted VPN ([comparison](#admin-vpn-tailscale-or-wireguard)) |
| Full tunnel | `y` routes **all** internet traffic from your devices through this server; `N` keeps the VPN for reaching the server only ([details](#full-tunnel-use-the-server-as-your-vpn-gateway)) |
| Tailscale auth key (Tailscale only) | Paste a key to skip the browser, or press Enter and open the login link it prints |
| Tailscale key expiry (Tailscale only) | In the Tailscale admin console, open **Machines**, select this server, and choose **Disable key expiry**. Then press Enter |
| WireGuard endpoint (WireGuard only) | Press Enter to accept the detected public address, or type a hostname. The script then prints a client config, waits for your client to connect, and refuses to continue without a handshake |
| **SSH verification** | Keep this terminal open. From a **new terminal**, run the command it shows: `ssh -i ~/keys/ADMIN-HOST.pem -o IdentitiesOnly=yes -p SSH_PORT ADMIN@TAILSCALE_IP`. If it works, type `yes`. If not, type `no` to roll back |
| CrowdSec enrollment key | Optional; press Enter to skip |
| Provider firewall | Set the rules it prints in your provider's firewall, then type `done`. Or type `not` (not yet) or `skip` (your provider has no firewall) |

Before any of these, Phase 2 checks that the admin user has a valid SSH key, and asks you to set a password if the user has none.

Phase 2 ends with a Lynis security audit and a summary of how to reach the server.

---

## After setup: final checks

1. **Health check**:
   ```bash
   ~/check-health.sh
   ```
2. **Reboot test**: after `sudo reboot`, reconnect:
   ```bash
   ssh -i ~/keys/ADMIN-HOST.pem -o IdentitiesOnly=yes -p SSH_PORT ADMIN@TAILSCALE_IP
   ```
3. **Emergency path**: `ssh ADMIN@TAILSCALE_IP` should work; this is Tailscale SSH on port 22. `ssh root@TAILSCALE_IP` should be refused.
4. **Emergency console**: log in with the admin password.
5. **Tailscale policy**: make sure Tailscale SSH can't log in as root. See [Tailscale SSH](#tailscale-ssh-emergency-path).
6. **Retire the provider's default user**, if your image has one, once everything above works:
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

### Admin VPN: Tailscale or WireGuard

Phase 2 asks which VPN carries admin SSH. Both use the WireGuard protocol; they differ in who manages keys and whether a second way in exists.

| | Tailscale (default) | Self-hosted WireGuard |
|---|---|---|
| Keys and devices | Managed for you; add a device by logging in | You generate keys and add each peer by hand |
| Public ports | None needed | One **public UDP port** (default 51820) |
| Behind NAT | Works anywhere | The server needs a reachable address |
| Access control | Tailnet policy, device approval, key expiry | Whoever holds a key gets in |
| Second way in | **Tailscale SSH** on port 22 | None: the provider console is the only fallback |
| Dependency | Tailscale's coordination service | Nothing outside your server |

Choose **Tailscale** if you want the easiest recovery. Choose **WireGuard** if you want no third-party service at all. The choice is saved in `/var/lib/server-setup/vpn-engine`, which the health check reads.

#### Tailscale

- Installed from Tailscale's official repository and logged in with `--ssh --accept-dns=true --accept-routes=false`.
- **Setup stops if Tailscale isn't active within 2 minutes**, before SSH is touched.
- `--accept-routes=false` stops a subnet route elsewhere in your tailnet from hijacking the server's own network.
- **Key expiry:** node keys expire after 180 days by default, and an expired key would cut off SSH. The script asks you to disable expiry, and `check-health.sh` keeps reporting it.
- A **tagged** server gets a warning, because tagged devices don't match the default Tailscale SSH rule.
- **Exit node:** answering yes to the full-tunnel question runs `tailscale set --advertise-exit-node`; approve it in the admin console and select it per device.

#### Tailscale auth keys

Every server joins your tailnet as its own device, so a new server normally needs a browser login. To skip it, create a key under **Tailscale admin console → Settings → Keys → Generate auth key**, then paste it at the prompt.

- **Kept out of logs:** the key is read hidden and passed as `--auth-key=file:<root-only temporary file>`, which is shredded right after use. It never appears in the process list, shell history or audit logs.
- **Fallback:** if Tailscale rejects the key, the script falls back to the browser login.

| Key setting | Recommendation |
|---|---|
| Reusable | Only for setting up several servers in a row; revoke it afterwards |
| Expiration | Short, 1–7 days |
| Pre-approved | On, if your tailnet requires device approval |
| Tags | Optional. Tagged servers have no key expiry, but need a matching Tailscale SSH rule (see below) |

> [!CAUTION]
> Anyone with an auth key can add devices to your tailnet. Treat it like a password and never commit it.

#### Tailscale SSH: emergency path

`--ssh` enables Tailscale SSH on port 22 of the Tailscale IP. It authenticates you through your Tailscale account instead of a key. That makes it a useful way in if sshd ever breaks, but it ignores `sshd_config`. **Your tailnet policy must stop it from logging in as root.**

In the Tailscale admin console, open **Access controls** and make the `ssh` rule use `autogroup:nonroot`:

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

- **Stricter:** `"users": ["ADMIN"]` allows only the admin user.
- **Check mode:** `"check"` asks you to re-confirm in the browser periodically.
- **Tagged servers:** use `"dst": ["tag:your-tag"]` instead of `autogroup:self`.
- **Protect your Tailscale login:** turn on two-factor login for the account you sign into Tailscale with, since that login now grants shell access.

#### Self-hosted WireGuard

- **Packages:** `wireguard-tools` and `qrencode`. The kernel module ships with Debian.
- **Addresses:** the server takes `10.66.66.1/24`, and your first client `10.66.66.2`. SSH then listens on `wg0` only.
- **Files** (all root-only, in `/etc/wireguard/`): `server.key`, `wg0.conf`, and `clients/ADMIN-HOST.conf` with its key.
- **Client config:** printed once during setup, with a QR code for phone apps. It's a **split tunnel**: only VPN traffic goes through WireGuard, so your normal internet is untouched.
- **Connection check:** setup waits up to 2 minutes for your client's first handshake and refuses to harden SSH without one. That check is what prevents a lockout, since WireGuard has no second way in.
- **Reruns keep `wg0.conf`,** so peers you added by hand survive. The admin peer is added only if missing.
- **Provider firewall:** UDP 51820 must be open, unlike Tailscale which needs no inbound rule.

Add another device (for example a phone) as `10.66.66.3`:

```bash
wg genkey | sudo tee /etc/wireguard/clients/phone.key | wg pubkey
```
```bash
sudo wg set wg0 peer PUBLIC_KEY_FROM_ABOVE allowed-ips 10.66.66.3/32
```
```bash
sudo wg-quick save wg0
```
The first command prints the public key, the second adds the peer live, and the third writes it into `wg0.conf`. Then build that device's config from the printed template, using its own private key and `Address = 10.66.66.3/32`.

> [!WARNING]
> With WireGuard there is no Tailscale SSH fallback. Keep the provider console working, and don't delete your client config.

#### Full tunnel: use the server as your VPN gateway

By default the VPN only carries traffic to the server itself (a split tunnel), so your normal browsing is untouched. Answer `y` to the full-tunnel question and the server becomes your **personal VPN gateway**: your devices send all internet traffic through it, which is what you want on public Wi-Fi or to leave from a fixed IP address.

| | Split tunnel (default) | Full tunnel |
|---|---|---|
| Client routes | Only the VPN subnet | Everything (`0.0.0.0/0`) |
| Your public IP while connected | Your own | The server's |
| Server bandwidth used | Almost none | All of your traffic |

**With WireGuard**, setup then:
- enables IPv4 forwarding in `/etc/sysctl.d/61-vpn-forward.conf`;
- adds a NAT rule for `10.66.66.0/24` in a marked block in `/etc/ufw/before.rules`, which deliberately avoids declaring the `POSTROUTING` chain so a firewall reload can't wipe Docker's own NAT rules;
- allows the forwarded traffic with `ufw route allow in on wg0 out on <your interface>`;
- writes `AllowedIPs = 0.0.0.0/0` in the client config.

**With Tailscale**, setup runs `tailscale set --advertise-exit-node`. You then **approve it** in the admin console (**Machines → this server → Edit route settings**) and pick it as your exit node on each device.

Two things to know:
- **IPv6 is not routed.** Turn IPv6 off on the client, or accept that IPv6-capable sites bypass the tunnel. (This applies to the WireGuard path; Tailscale exit nodes handle IPv6 themselves.)
- **DNS stays as the client has it.** Queries travel through the tunnel, but to whichever resolver the device already uses. Add a `DNS = ...` line to the client config to change that.

To switch later, rerun Phase 2 and answer the question differently, then re-import the client config.

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
- **No `ListenAddress`**, on purpose. SSH can start before Tailscale at boot, so the Tailscale-only restriction is enforced by the firewall instead.

**Lockout protection:**
1. **Pre-flight checks:** the admin user must have a valid key and a password before anything changes.
2. **Snapshot and rollback timer:** the current SSH config and firewall rules are saved, and a 10-minute automatic rollback is armed.
3. **Validation:** the new config must pass `sshd -t`, SSH must be running, and the new port must be listening.
4. **Your confirmation:** you test the login from a new terminal and type `yes`. If you're too late and the rollback already ran, the script stops instead of pretending the server is hardened.
5. **Rollback:** it restores the state from **just before this run**, so a rerun on a hardened server stays Tailscale-only instead of reopening port 22.

### Firewalls

<details>
<summary><b>UFW rules</b></summary>

```bash
ufw default deny incoming
ufw default allow outgoing
ufw default deny forward
ufw allow 80/tcp  comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw allow 443/udp comment 'HTTP/3 (Caddy)'
ufw allow in on tailscale0 to any port SSH_PORT proto tcp comment 'SSH via Tailscale only'
```
</details>

**Provider firewall.** At the end of Phase 2, the script prints these rules for your provider's firewall or security group:

| Rule | Why |
|---|---|
| Allow TCP 80 from `0.0.0.0/0` and `::/0` | HTTP and HTTPS certificate issuance |
| Allow TCP 443 from `0.0.0.0/0` and `::/0` | HTTPS |
| Allow UDP 443 from `0.0.0.0/0` and `::/0` | HTTP/3 (optional; browsers fall back to TCP) |
| Allow UDP 41641 from `0.0.0.0/0` and `::/0` | Optional: direct Tailscale connections instead of relays |
| Allow UDP 51820 from `0.0.0.0/0` and `::/0` | **Required with WireGuard**; not needed with Tailscale |
| **Remove TCP 22, and add no SSH rule** | SSH travels inside Tailscale |
| Allow all outbound | Tailscale, updates, CrowdSec, Docker |

Your answer (`done`, `not` or `skip`) is saved in `/var/lib/server-setup/provider-firewall`. If it's `not`, `check-health.sh` keeps reminding you. When you've set the rules, mark it done with:
```bash
echo done | sudo tee /var/lib/server-setup/provider-firewall
```

### CrowdSec

- **Components:** the official engine plus the **nftables firewall bouncer**, with the `linux`, `sshd` and `caddy` collections. The hub updates daily.
- **Log sources:** `/var/log/auth.log`, `/var/log/syslog` and the Caddy access log. SSH events are read once, so failed logins aren't counted twice.
- **Tailscale addresses are never banned** (`100.64.0.0/10`, `fd7a:115c:a1e0::/48`). Otherwise a few failed key attempts from your own laptop could ban your Tailscale IP and lock you out.
- **Debian 13 support:** a custom parser handles Debian 13's `sshd-session` log lines.
- **Optional:** enrollment in the CrowdSec console.

<details>
<summary><b>CrowdSec files</b></summary>

`/etc/crowdsec/parsers/s02-enrich/tailscale-whitelist.yaml`
```yaml
name: custom/tailscale-whitelist
description: "Never ban Tailscale addresses; admin SSH arrives from them"
whitelist:
  reason: "Tailscale admin network"
  cidr:
    - "100.64.0.0/10"
    - "fd7a:115c:a1e0::/48"
```

`/etc/crowdsec/parsers/s00-raw/debian13-sshd-session.yaml`
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

`/etc/crowdsec/acquis.yaml`
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
</details>

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
| What updates | Debian (stable, point releases, security), Tailscale, CrowdSec, Caddy, and Docker when chosen. Podman comes from Debian itself |
| When | Package lists at 02:30, installs at **03:30 server time**. A missed window is skipped |
| Config files | Kept (`--force-confold`), so an upgrade never resets `sshd_config`, UFW rules or the Caddyfile |
| Services | `needrestart` restarts services that still use old libraries |
| Reboots | **Manual**. `check-health.sh` shows when a reboot is needed |

At the end, Phase 2 verifies that every repository is covered and runs a dry run.

### Caddy web server

- **Install and HTTPS:** installed from Caddy's official repository, with automatic HTTPS for real domain names and HTTP/3.
- **`/etc/caddy/Caddyfile`** is managed by the script and replaced on reruns. It holds:
  - the shared `site_defaults` snippet: compression, security headers including HSTS, no `Server` header, a JSON access log, and a 404 for dotfiles such as `.git` and `.env`;
  - a default site on port 80 with `/health`.
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

### Containers: Docker or Podman

Phase 2 asks which engine to install. Both are hardened; they differ in how much root they need.

| | Docker (default) | Rootless Podman |
|---|---|---|
| Containers run as | root | your admin user |
| Root-equivalent group | Yes: the admin user joins the `docker` group | None |
| Firewall | Docker's own rules skip UFW, so the setup adds rules to put containers back behind it | Published ports go through the normal path, so UFW applies |
| Compose | `docker compose` (reference implementation) | `podman-compose`; occasional differences on complex files |
| Updates | Docker's own repository, added to the nightly updates | Debian's own repositories |
| Tooling that needs a Docker socket | Works | Often needs extra work |

Pick **Docker** if you use Compose files or tools that talk to the Docker socket. Pick **Podman** if you want the strongest isolation and your apps are plain services behind Caddy.

Your choice is saved in `/var/lib/server-setup/container-engine`, which the health check reads.

#### Docker

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

#### Rootless Podman

- **Packages:** `podman`, `podman-docker` (so `docker …` commands still work), `podman-compose`, plus `uidmap` and `passt` for rootless networking.
- **Runs as your admin user.** There is no daemon and no root-equivalent group. A container breakout lands as that user, not root.
- **Starts at boot:** lingering is enabled for the admin user, so rootless containers come back after a reboot without anyone logging in.
- **Enabled for that user:** the Podman socket (for Compose and other tools) and the image auto-update timer.
- **Log size** is capped in `/etc/containers/containers.conf.d/99-hardening.conf`.

Two differences to keep in mind:

```bash
podman run -p 127.0.0.1:3000:80 image     # always name the address: Podman has no default bind address
```
- **Don't use `sudo podman`.** Rootful containers get firewall rules that bypass UFW, exactly like Docker's.

### GitHub deploy keys

GitHub allows each deploy key on **one repository only**, so the server gets a helper instead of a shared key. Run it as the admin user, without `sudo`:

```bash
~/github-deploy-key.sh OWNER/REPO
```

It:
1. creates `~/.ssh/deploy_OWNER_REPO` (Ed25519);
2. adds a `Host github-OWNER-REPO` alias to `~/.ssh/config`;
3. trusts GitHub's host key only if it matches GitHub's published fingerprint;
4. prints the public key to add under **Repository → Settings → Deploy keys**;
5. tests the connection.

Clone using the alias:

```bash
git clone git@github-OWNER-REPO:OWNER/REPO.git
```

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
- VPN status: Tailscale connection and key expiry, or WireGuard peer handshakes, plus whether the full tunnel is on;
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
| SSH port | `2743` | Prompted in Phase 2 (`DEFAULT_SSH_PORT` in `setup.sh`) |
| Container engine | `docker` | Prompted in Phase 2 (`DEFAULT_CONTAINER_ENGINE` in `setup.sh`) |
| Admin VPN | `tailscale` | Prompted in Phase 2 (`DEFAULT_VPN_ENGINE` in `setup.sh`) |
| WireGuard port and subnet | `51820`, `10.66.66.0/24` | `WG_PORT` and `WG_SUBNET` in `setup.sh` |
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
  - On a hardened server, it prints commands that use the Tailscale IP and SSH port.
  - It offers to add new admins to `AllowUsers`.
- **`setup.sh`:**
  - SSH port, auth key and firewall prompts: on a rerun, pressing Enter at the port prompt keeps the current port, and there's no auth-key prompt if Tailscale is already logged in. The provider firewall question isn't asked again once answered `done` or `skip`.
  - Existing admins stay in `AllowUsers`.
  - Switching VPN: the new one is configured, but the old one is left installed. An existing `wg0.conf` is never overwritten.
  - Switching container engine: the new engine is installed, but the old one is left in place. Remove it yourself once the new one works, since both compete for published ports.
  - Changing the SSH port closes the old port's firewall rule.

**Servers set up by older versions:**
- **Nginx:** Phase 2 disables Nginx and switches to Caddy, asking first if Nginx serves custom sites. The package and `/etc/nginx` are kept.
- **Old shared GitHub key:** a leftover `~/.ssh/github` key is reported but not deleted.
- **`ListenAddress` lines:** leftover lines from older versions are removed from `sshd_config`.

---

## Troubleshooting and recovery

If you can't reach the server over Tailscale, log in through your **provider's emergency console** with the admin password, then run `sudo -i`.

| Problem | Fix |
|---|---|
| `Permission denied (publickey)` | Use `-i ~/keys/ADMIN-HOST.pem -o IdentitiesOnly=yes`. With several keys in your SSH agent, the server's limit of 3 attempts runs out before the right key |
| `setlocale: cannot change locale` | Run `sudo localedef -i en_US -f UTF-8 en_US.UTF-8`, then log in again |
| Tailscale logged out or key expired | Run `tailscale up --ssh --accept-dns=true --accept-routes=false`, open the link, then disable key expiry |
| WireGuard tunnel down | Run `systemctl restart wg-quick@wg0`, then check `wg show` |
| WireGuard never connects | Check that the provider firewall allows UDP 51820, that the client's `Endpoint` address is right, and that its key matches a peer in `wg0.conf` |
| Banned by CrowdSec | Run `cscli decisions list`, then `cscli decisions delete --ip YOUR_IP` |
| Firewall blocks you | Run `ufw disable`, fix the rules, then `ufw enable` |
| Undo the last SSH change | Run `cp /etc/ssh/sshd_config.pre-run /etc/ssh/sshd_config && systemctl restart ssh`. The original distro config is in `sshd_config.bak` |
| Boot stuck in emergency mode | The console opens a root shell. Fix `/etc/fstab` or the failed mount, then reboot |
| Lost the `.pem` key | From the console, rerun `bootstrap.sh`, reconfigure the user, and copy the new key with `show` |
| Old SSH client rejected | Update the client; the server allows only modern algorithms |
| Undo the Docker firewall rules | Delete the `# BEGIN UFW AND DOCKER` … `# END UFW AND DOCKER` block in `/etc/ufw/after.rules`, then run `ufw reload` |

---

## Security notes and limitations

- **With Tailscale, your Tailscale login is as powerful as the SSH key**, because it grants Tailscale SSH access. Protect it with two-factor login and keep check mode on.
- **With a full tunnel, all your device traffic passes through the server**, so its provider sees it, its bandwidth carries it, and websites see its IP. Datacenter IP addresses are sometimes rate-limited or blocked.
- **With WireGuard, there is no second way in.** If the tunnel breaks or you lose the client config, the provider console is your only route. You also manage keys by hand, and one public UDP port stays open.
- **With Docker, the `docker` group is root-equivalent.** The admin user is a member. Protect the SSH key with a passphrase, remove the user from the group (`sudo gpasswd -d ADMIN docker`) and use `sudo docker`, or choose rootless Podman instead.
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
