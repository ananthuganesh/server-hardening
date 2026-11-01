# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Two interactive Bash scripts that turn a fresh Debian 13 (Trixie) server into a hardened server, a small helper (`fetch-key.sh`) that runs on the admin's computer, plus a public-facing README. The README covers the quick start, a reference of every generated config (long listings in `<details>` blocks), operations and recovery. Keep it in plain English, provider-neutral, and free of personal or server-specific data. There is no build system, package manager, or test suite. The scripts are edited here on macOS and **run only on the target server** (`scp bootstrap.sh setup.sh root@IP:/root/`). Never run them locally: they change users, sshd, the firewall, sysctl and more.

**Scope decisions (from the user):**
- **Debian only.** `detect_os` exits on any non-Debian system; Debian releases other than 13 need a confirmation prompt. Do not add Ubuntu or other distro branches.
- **Provider-neutral.** The servers run on several cloud providers, so don't name or call provider-specific APIs, metadata endpoints or consoles in the scripts or README. Say "your provider's web/emergency console" and "provider firewall / security group".
- **No hardcoded names.** Don't add defaults like a hostname or username. The hostname prompt defaults to the current hostname, and the username is required. The timezone **Asia/Kolkata** is fixed without a prompt. The SSH port is **prompted** in `setup.sh` (`prompt_ssh_port`) with **no suggested value**: a first run requires the admin to type one, and a rerun offers the port sshd already uses so Enter keeps it. It must be 1024–65535 and not in use by another program, not 2019/6060/8080 (Caddy/CrowdSec), 22 stays excluded by choice: bots scan it first.
- **Provider firewall is a prompt, not automation.** `confirm_provider_firewall` (last step, after Lynis) prints the provider-neutral rules, then asks `done/not/skip`. It stores `done|pending|skipped` in `/var/lib/server-setup/provider-firewall`, which `check-health.sh` reads. It isn't asked again once `done` or `skipped`. Don't call provider APIs.
- **Public repo.** Never commit keys, tokens, enrollment keys or real server IPs/hostnames; `.gitignore` blocks `*.pem`, `*.key` and `id_*`.
- **No VPN.** Do not add any VPN back without asking. SSH is reached directly on the chosen port, with key-only login. WireGuard and Podman were removed earlier (user decision).
- **SSH is open to all addresses, by user decision** (the admin has no fixed IP). The protection is key-only login, root login off, `AllowUsers`, and CrowdSec. Do not re-add an admin-address restriction unless the user asks for it.
- **Docker is the only container engine.** Podman was tried and removed (user decision); don't add it or another engine back. `main()` calls `configure_docker` directly, the Docker origin is always added to unattended-upgrades and always checked by `verify_automatic_updates`, and `configure_docker_firewall` always runs.
- **Web server is Caddy, not Nginx.**

## Checking changes

No tests exist. Before committing, at minimum run:

```bash
bash -n bootstrap.sh setup.sh
```

```bash
shellcheck bootstrap.sh setup.sh
```

shellcheck isn't installed on this Mac (`brew install shellcheck`). Two more checks work locally:
- Render the generated `sshd_config` and run macOS `/usr/sbin/sshd -t -f <file>` on it. Strip the Debian-only `DebianBanner` line and the `Include` line first.
- Exercise `filter_ssh_algorithms` against the local `ssh -Q`.

The only real test is running them on a disposable Debian 13 VM with the provider's emergency console open.

## Architecture

**Two phases, two privilege contexts:**
- `bootstrap.sh` runs as root, or with `sudo` on images that disable root login. It creates or reconfigures the admin user (sudo group, password, `authorized_keys`, PATH/locale in `.bashrc`) and copies `setup.sh` into that user's home. On reruns it still refreshes `setup.sh` even when the user is not reconfigured. All prompts are gathered first; actions come after.
- **SSH login keys are server-generated Ed25519 .pem only** (user decision). Don't re-add a "paste your public key" option or a key-type choice. `require_ssh_keygen` checks for `ssh-keygen` during the prompts. `generate_pem_key` creates the Ed25519 key (OpenSSH format) named `ADMIN-HOSTNAME.pem`, and `setup.sh` prints SSH commands using that filename. The private key goes in the home of the account running the script (`$SUDO_USER` or root) so it can be scp'd over the working session. `finish_pem_key_handoff` ends the script with a `delete`/`show`/`keep` prompt for the server copy.
- **Phase 1 is run only on the server** (`sudo ./bootstrap.sh`; user decision). The only local helper is `fetch-key.sh`, which the user runs on their own computer. It copies the `.pem` from the server into `~/keys` (`LOCAL_KEY_DIR`) with `chmod 600`, checks the key, and never deletes the server copy. It doesn't run Phase 1 or Phase 2. At the end, `bootstrap.sh` prints the `fetch-key.sh` command, then the `delete`/`show`/`keep` prompt.
- `setup.sh` runs as `sudo ./setup.sh` from the admin user's home. `main()` at the bottom calls one `configure_*` function per section, in order. **The order is load-bearing:** base system → swap → SSH hardening (which calls `configure_ufw_firewall`) → lock root → CrowdSec → kernel → security packages (which calls `configure_automatic_updates`) → Caddy → Docker → `~/check-health.sh` → `verify_automatic_updates` (dry run, needs all repos present) → Lynis.
- **Ask once.** Hostname and admin username are asked only in `bootstrap.sh`, and the timezone is fixed there; don't add those prompts back to `setup.sh`.
  - `resolve_target_user` takes the admin user from `$SUDO_USER` and prompts only when that is empty or root.
  - `verify_environment` reads `HOSTNAME_VAL` from `hostname -s`.
  - `bootstrap.sh` applies the hostname and timezone before anything else, so the `.pem` filename uses the new hostname. It also writes `/etc/cloud/cloud.cfg.d/99-preserve-hostname.cfg` so cloud-init doesn't reset the hostname or `/etc/hosts` at boot.
  - On reruns after Phase 2, `detect_ssh_access` reads the port from `sshd -T`, so the printed ssh/scp commands still work. `bootstrap.sh` writes its public address to `/var/lib/server-setup/public-address`, which `setup.sh` prints in its SSH test command.
- **No GitHub deploy key helper.** The projects set up their own GitHub access later. `git` is installed in the base packages, and nothing else is written for GitHub.

**Lockout-prevention design (the most sensitive code, change it with care):**
- Pre-flight in `verify_environment`, before anything changes:
  - `check_admin_ssh_keys`: `authorized_keys` must contain a valid key, and it fixes the `StrictModes` permissions.
  - `ensure_admin_password`: `passwd -S` must report `P`. Root gets locked, and the emergency console needs a password.
- The SSH safety gate runs from the admin's computer. If the test fails, the rollback restores the previous config, as long as the rollback timer runs.
  - Don't add a second (journalctl) CrowdSec source for sshd: it would double-count failures.
  - The bouncer is **restarted** after its API key is replaced; `enable --now` would leave it running on a deleted key.
  - CrowdSec's LAPI listens on `127.0.0.1:8080`, so examples must never publish containers on host port 8080.
  - The provider's emergency console is the fallback if SSH breaks. Root is locked, so the admin password must be set (`ensure_admin_password`).
- `configure_ssh_hardening` backs up `/etc/ssh/sshd_config.bak` once (the original distro config, never overwritten). Each run it also snapshots the live `sshd_config.pre-run`, plus UFW `user*.rules` and a `was-active` flag in `/root/ufw-pre-run/`. It then arms a `systemd-run` transient timer (`ssh-hardening-rollback`, 10 min) that runs `/root/ssh-hardening-rollback.sh`. It refuses to continue if `systemd-run` is missing.
  - A rollback (timer, "no", or a failed check) restores **the pre-run snapshot**. UFW is disabled only if it was inactive before the run; otherwise the previous rules are restored. Restoring `.bak` on a rerun would reopen port 22 publicly with UFW off.
- `AllowUsers` merges `$TARGET_USER` with the users already allowed (read via `sshd -T`) when the server is already hardened, so a second admin running setup never drops the first. `bootstrap.sh` (`ensure_user_allowed_by_sshd`) offers to append a new user to `AllowUsers` on hardened servers.
- `lock_down_root` adds `SYSTEMD_SULOGIN_FORCE=1` drop-ins for `emergency.service`/`rescue.service`. With root locked, sulogin would otherwise refuse the emergency shell and the console would be useless after a boot failure.
- Both scripts set `umask 022`. After the first run, login shells (and sudo) inherit `umask 027`, which would make rewritten apt configs, banners and repo lists unreadable to normal users.
- After writing sshd_config (`Port $TARGET_PORT`, `AllowUsers $TARGET_USER`), it runs these checks: `sshd -t`; `sshd -T` to confirm the effective port, root login, password login and public-key login weren't overridden by a cloud-image drop-in in `sshd_config.d`; that the service is active; and that the port is listening. Any failure calls `perform_ssh_rollback_now`. UFW is configured *before* the yes/no verification prompt so the user tests the final firewall state. After a "yes", the script re-checks the effective port and that UFW is active. If the answer came after the 10-minute timer already rolled back, it exits instead of continuing as if hardened. Use here-strings rather than `cmd | grep -q` for such checks: with `pipefail`, `grep -q` can close the pipe early and turn a match into a failure.
- SSH crypto: `filter_ssh_algorithms` intersects the wanted KEX, cipher, MAC and host-key algorithm lists with `ssh -Q`, because one unknown name makes `sshd -t` fail. It omits a directive when nothing matches. `prepare_ssh_host_keys` runs `ssh-keygen -A`, regenerates RSA host keys under 3072 bits, and strips `/etc/ssh/moduli` entries under 3072 bits (`moduli.bak` is kept). `PubkeyAcceptedAlgorithms` and `RequiredRSASize` are deliberately **not** set: that could reject the admin's existing ECDSA or 2048-bit RSA key and lock them out.
- The hardened settings sit above the `Include` line on purpose, because sshd keeps the first value it reads for each keyword.
- sshd deliberately has **no `ListenAddress`**, so it doesn't need to bind to one interface. UFW allows `$TARGET_PORT/tcp` from all addresses. A `sed` strips leftover `ListenAddress` lines from older versions. Do not reintroduce binding.

**Conventions:**
- `set -euo pipefail` everywhere. Steps that are allowed to fail use `|| log_warning ...` or `|| true` so reruns don't abort. Examples: CrowdSec collection installs, rkhunter, auditd reload, optional cron paths. Wrap commands whose non-zero exit is expected in `set +e`/`set -e`, as the health check's `curl` probe does. Lynis exit codes 1–63 mean warnings; only 64 and above count as failures.
- Scripts must be **rerun-safe**: check before appending (`grep -q ... || echo >>`), use `sed -i` to replace existing keys, and skip installs that are already present (Docker).
- Config files are written with heredocs. Use quoted `<< 'EOF'` for literal content. Use unquoted `<< EOF` only when variables such as `$TARGET_PORT`, `$TARGET_USER` or `$HOSTNAME_VAL` must expand, and escape `$` inside them. The Caddyfile, the apt configs (`${distro_codename}`) and the needrestart Perl config (`$nrconf`) must stay in quoted heredocs.
- Logging goes through `log_info`, `log_success`, `log_warning` and `log_error`, which are duplicated in both scripts. User input is validated by `validate_linux_username` (also duplicated) and a hostname regex.
- Tunables are globals at the top of `setup.sh`: `LYNIS_TARGET_SCORE=83`, rollback delay.
- `99-hardening.conf` deliberately does not set `ip_forward = 0`. Docker needs forwarding, and any later `sysctl --system` would break containers.
- Debian 13 specifics: OpenSSH logs as `sshd-session`. Handling it needs the rsyslog rule routing it to `/var/log/auth.log` and the custom CrowdSec parser `s00-raw/debian13-sshd-session.yaml`. Keep both.
- Caddy (`configure_caddy`):
  - **Ownership split:** `/etc/caddy/Caddyfile` is script-owned and overwritten on reruns. It holds the `site_defaults` snippet, the default `:80` site with `/health`, and `import /etc/caddy/sites/*.caddy`. User sites live in `/etc/caddy/sites/` (`root:caddy`, mode 2750), which reruns must never touch.
  - **Validation:** the new Caddyfile is written to `Caddyfile.new` and validated with `runuser -u caddy` (running as root would create root-owned log files Caddy can't write). It is only moved into place if valid.
  - **Permissions:** the `027` umask means anything Caddy reads needs explicit 644 or group `caddy`.
  - **Nginx migration:** `retire_nginx` disables Nginx from older installs. It asks first when non-default Nginx sites exist, and never purges the package.
- Automatic updates (`configure_automatic_updates`):
  - `unattended-upgrades` on overridden `apt-daily*.timer` drop-ins (lists at 02:30, install at 03:30, `Persistent=false`) instead of a raw cron job.
  - Origins-Pattern entries must match each repo's Release `Origin`/`Label`: `Docker`/`Docker CE`, `packagecloud.io/crowdsec/crowdsec`, `cloudsmith/caddy/stable`. When adding a repo, add its origin too.
  - `Dpkg::Options --force-confold` keeps modified configs (an upgraded `sshd_config` must never revert).
  - needrestart auto-restarts services; automatic reboot stays off.
  - `verify_automatic_updates` checks that each `o=<origin>,` appears in `apt-cache policy`, and looks for errors in the dry run. "Allowed origins are" is printed at startup, so it proves nothing.
- Docker (`configure_docker`):
  - `write_docker_daemon_config` sets `ip: 127.0.0.1`, `icc: false`, `no-new-privileges` and `live-restore`. It validates with `dockerd --validate` when available and restores `daemon.json.bak` if Docker won't restart.
  - `configure_docker_firewall` appends a marker-delimited `# BEGIN/END UFW AND DOCKER` block (ufw-docker's DOCKER-USER rules) to `/etc/ufw/after.rules`. Reruns delete the block with `sed` and append it again. If `ufw reload` fails, it restores `after.rules.pre-docker.bak`.
  - This step runs after the SSH gate, so a firewall mistake here cannot cause an SSH lockout.
- When the SSH port changes between runs, `configure_ufw_firewall` deletes the rule for `PREVIOUS_SSH_PORT`. It is read in `prompt_ssh_port` before sshd_config is rewritten.

## Keep README in sync

README.md repeats much of what `setup.sh` writes: sshd_config, UFW rules, CrowdSec parser/acquis, sysctl modules, auditd rules, Caddy layout, automatic update schedule, swap sizing, prompts and defaults. If you change a generated config, a port, a default, or the order of prompts, update the matching README section too.
