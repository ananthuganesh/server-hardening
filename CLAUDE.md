# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Two interactive Bash scripts that turn a fresh Debian 13 (Trixie) server into a hardened server, plus a README that doubles as a manual reference for every step. There is no build system, package manager, or test suite. The scripts are edited here on macOS and **run only on the target server** (`scp bootstrap.sh setup.sh root@IP:/root/`). Never run them locally: they change users, sshd, the firewall, sysctl and more.

**Scope decisions (from the user):**
- **Debian only.** `detect_os` exits on any non-Debian system; Debian releases other than 13 need a confirmation prompt. Do not add Ubuntu or other distro branches.
- **Provider-neutral.** The servers run on several cloud providers, so don't name or call provider-specific APIs, metadata endpoints or consoles in the scripts or README. Say "your provider's web/emergency console" and "provider firewall / security group".
- **No hardcoded names.** Don't add defaults like a hostname or username. The hostname prompt defaults to the current hostname, and the username is required. The timezone **Asia/Kolkata** is fixed without a prompt. The SSH port is **prompted** in `setup.sh` (`prompt_ssh_port`): the default is 2743, or the current sshd port on reruns. It must be 1024–65535 and not in use by another program, not 2019/6060/8080 (Caddy/CrowdSec), and never 22, because Tailscale SSH owns port 22 on the Tailscale IP.
- **Public repo.** Never commit keys, tokens, enrollment keys or real server IPs/hostnames; `.gitignore` blocks `*.pem`, `*.key` and `id_*`.
- **Web server is Caddy, not Nginx.** Tailscale SSH (`--ssh`) stays enabled as an emergency path; the user restricts it to non-root in the tailnet policy, which the script only reminds about.

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
- **Phase 1 is run only on the server** (`sudo ./bootstrap.sh`; user decision). There is no local helper that runs it remotely or downloads the key; don't add one. At the end, `bootstrap.sh` prints download commands that save into `LOCAL_KEY_DIR` (`~/keys` on the admin's computer, printed literally), then the `delete`/`show`/`keep` prompt.
- `setup.sh` runs as `sudo ./setup.sh` from the admin user's home. `main()` at the bottom calls one `configure_*` function per section, in order. **The order is load-bearing:** base system → swap → Tailscale → SSH hardening (which calls `configure_ufw_firewall`) → lock root → CrowdSec → kernel → security packages (which calls `configure_automatic_updates`) → Caddy → Docker → GitHub deploy key helper → `~/check-health.sh` → `verify_automatic_updates` (dry run, needs all repos present) → Lynis.
- **Ask once.** Hostname and admin username are asked only in `bootstrap.sh`, and the timezone is fixed there; don't add those prompts back to `setup.sh`.
  - `resolve_target_user` takes the admin user from `$SUDO_USER` and prompts only when that is empty or root.
  - `verify_environment` reads `HOSTNAME_VAL` from `hostname -s`.
  - `bootstrap.sh` applies the hostname and timezone before anything else, so the `.pem` filename uses the new hostname. It also writes `/etc/cloud/cloud.cfg.d/99-preserve-hostname.cfg` so cloud-init doesn't reset the hostname or `/etc/hosts` at boot.
  - On reruns after Phase 2, `detect_ssh_access` reads the port from `sshd -T` and the Tailscale IP, so the printed ssh/scp commands still work.
- **GitHub uses per-project deploy keys only.** GitHub allows a deploy key on just one repo, so Phase 2 creates no shared GitHub key. It installs `~/github-deploy-key.sh OWNER/REPO` (a quoted `HELPER` heredoc in `setup.sh`), which:
  - creates `~/.ssh/deploy_OWNER_REPO`;
  - appends a `Host github-OWNER-REPO` alias to `~/.ssh/config` (append-only; never overwrite that file);
  - pins GitHub's host key to its published Ed25519 fingerprint;
  - tests authentication.

**Lockout-prevention design (the most sensitive code, change it with care):**
- Pre-flight in `verify_environment`, before anything changes:
  - `check_admin_ssh_keys`: `authorized_keys` must contain a valid key, and it fixes the `StrictModes` permissions.
  - `ensure_admin_password`: `passwd -S` must report `P`. Root gets locked, and the emergency console needs a password.
- Tailscale must be up (`tailscale up`, 2-minute wait) before SSH is touched; the script exits on failure. After Phase 2, Tailscale is the only SSH path, so:
  - `check_tailscale_key_expiry` stops and asks the user to disable node key expiry. `check-health.sh` reports it too.
  - Keep `--accept-routes=false`: an overlapping subnet route can hijack the server's own network.
  - The CrowdSec parser whitelist `s02-enrich/tailscale-whitelist.yaml` (100.64.0.0/10, fd7a:115c:a1e0::/48) must stay. Without it, failed key attempts ban the admin's Tailscale IP, and the nftables bouncer blocks that on `tailscale0` too.
  - Don't add a second (journalctl) CrowdSec source for sshd: it would double-count failures.
  - Existing Tailscale bans are removed with `cscli decisions delete --range ... --contained`. Without `--contained`, only a ban on the exact range would match.
  - The bouncer is **restarted** after its API key is replaced; `enable --now` would leave it running on a deleted key.
  - CrowdSec's LAPI listens on `127.0.0.1:8080`, so examples must never publish containers on host port 8080.
  - Reruns use `tailscale set` when `BackendState` is `Running`. `tailscale up` fails unless every non-default setting is repeated.
- `configure_ssh_hardening` backs up `/etc/ssh/sshd_config.bak` once (the original distro config, never overwritten). Each run it also snapshots the live `sshd_config.pre-run`, plus UFW `user*.rules` and a `was-active` flag in `/root/ufw-pre-run/`. It then arms a `systemd-run` transient timer (`ssh-hardening-rollback`, 10 min) that runs `/root/ssh-hardening-rollback.sh`. It refuses to continue if `systemd-run` is missing.
  - A rollback (timer, "no", or a failed check) restores **the pre-run snapshot**. UFW is disabled only if it was inactive before the run; otherwise the previous rules are restored. Restoring `.bak` on a rerun would reopen port 22 publicly with UFW off.
- `AllowUsers` merges `$TARGET_USER` with the users already allowed (read via `sshd -T`) when the server is already hardened, so a second admin running setup never drops the first. `bootstrap.sh` (`ensure_user_allowed_by_sshd`) offers to append a new user to `AllowUsers` on hardened servers.
- `lock_down_root` adds `SYSTEMD_SULOGIN_FORCE=1` drop-ins for `emergency.service`/`rescue.service`. With root locked, sulogin would otherwise refuse the emergency shell and the console would be useless after a boot failure.
- Both scripts set `umask 022`. After the first run, login shells (and sudo) inherit `umask 027`, which would make rewritten apt configs, banners and repo lists unreadable to normal users.
- After writing sshd_config (`Port $TARGET_PORT`, `AllowUsers $TARGET_USER`), it runs these checks: `sshd -t`; `sshd -T` to confirm the effective port, root login, password login and public-key login weren't overridden by a cloud-image drop-in in `sshd_config.d`; that the service is active; and that the port is listening. Any failure calls `perform_ssh_rollback_now`. UFW is configured *before* the yes/no verification prompt so the user tests the final firewall state. After a "yes", the script re-checks the effective port and that UFW is active. If the answer came after the 10-minute timer already rolled back, it exits instead of continuing as if hardened. Use here-strings rather than `cmd | grep -q` for such checks: with `pipefail`, `grep -q` can close the pipe early and turn a match into a failure.
- SSH crypto: `filter_ssh_algorithms` intersects the wanted KEX, cipher, MAC and host-key algorithm lists with `ssh -Q`, because one unknown name makes `sshd -t` fail. It omits a directive when nothing matches. `prepare_ssh_host_keys` runs `ssh-keygen -A`, regenerates RSA host keys under 3072 bits, and strips `/etc/ssh/moduli` entries under 3072 bits (`moduli.bak` is kept). `PubkeyAcceptedAlgorithms` and `RequiredRSASize` are deliberately **not** set: that could reject the admin's existing ECDSA or 2048-bit RSA key and lock them out.
- The hardened settings sit above the `Include` line on purpose, because sshd keeps the first value it reads for each keyword.
- sshd deliberately has **no `ListenAddress`** bound to the Tailscale IP, because sshd can start before `tailscale0` has an address at boot. The Tailscale-only restriction is enforced by the UFW rule `allow in on tailscale0 to any port $TARGET_PORT`. A `sed` strips leftover `ListenAddress` lines from older versions. Do not reintroduce binding.

**Conventions:**
- `set -euo pipefail` everywhere. Steps that are allowed to fail use `|| log_warning ...` or `|| true` so reruns don't abort. Examples: CrowdSec collection installs, rkhunter, auditd reload, optional cron paths. Wrap commands whose non-zero exit is expected in `set +e`/`set -e`, as the deploy key helper's SSH test does. Lynis exit codes 1–63 mean warnings; only 64 and above count as failures.
- Scripts must be **rerun-safe**: check before appending (`grep -q ... || echo >>`), use `sed -i` to replace existing keys, and skip installs that are already present (Tailscale, Docker).
- Config files are written with heredocs. Use quoted `<< 'EOF'` for literal content. Use unquoted `<< EOF` only when variables such as `$TARGET_PORT`, `$TARGET_USER` or `$HOSTNAME_VAL` must expand, and escape `$` inside them. The Caddyfile, the apt configs (`${distro_codename}`) and the needrestart Perl config (`$nrconf`) must stay in quoted heredocs.
- Logging goes through `log_info`, `log_success`, `log_warning` and `log_error`, which are duplicated in both scripts. User input is validated by `validate_linux_username` (also duplicated) and a hostname regex.
- Tunables are globals at the top of `setup.sh`: `DEFAULT_SSH_PORT=2743` (prompt default), `LYNIS_TARGET_SCORE=83`, rollback delay.
- `99-hardening.conf` deliberately does not set `ip_forward = 0`. Docker needs forwarding, and any later `sysctl --system` would break containers.
- Debian 13 specifics: OpenSSH logs as `sshd-session`. Handling it needs the rsyslog rule routing it to `/var/log/auth.log` and the custom CrowdSec parser `s00-raw/debian13-sshd-session.yaml`. Keep both.
- Caddy (`configure_caddy`):
  - **Ownership split:** `/etc/caddy/Caddyfile` is script-owned and overwritten on reruns. It holds the `site_defaults` snippet, the default `:80` site with `/health`, and `import /etc/caddy/sites/*.caddy`. User sites live in `/etc/caddy/sites/` (`root:caddy`, mode 2750), which reruns must never touch.
  - **Validation:** the new Caddyfile is written to `Caddyfile.new` and validated with `runuser -u caddy` (running as root would create root-owned log files Caddy can't write). It is only moved into place if valid.
  - **Permissions:** the `027` umask means anything Caddy reads needs explicit 644 or group `caddy`.
  - **Nginx migration:** `retire_nginx` disables Nginx from older installs. It asks first when non-default Nginx sites exist, and never purges the package.
- Automatic updates (`configure_automatic_updates`):
  - `unattended-upgrades` on overridden `apt-daily*.timer` drop-ins (lists at 02:30, install at 03:30, `Persistent=false`) instead of a raw cron job.
  - Origins-Pattern entries must match each repo's Release `Origin`/`Label`: `Tailscale`, `Docker`/`Docker CE`, `packagecloud.io/crowdsec/crowdsec`, `cloudsmith/caddy/stable`. When adding a repo, add its origin too.
  - `Dpkg::Options --force-confold` keeps modified configs (an upgraded `sshd_config` must never revert).
  - needrestart auto-restarts services; automatic reboot stays off.
  - `verify_automatic_updates` checks that each `o=<origin>,` appears in `apt-cache policy`, and looks for errors in the dry run. "Allowed origins are" is printed at startup, so it proves nothing.
- Docker (`configure_docker`):
  - `write_docker_daemon_config` sets `ip: 127.0.0.1`, `icc: false`, `no-new-privileges` and `live-restore`. It validates with `dockerd --validate` when available and restores `daemon.json.bak` if Docker won't restart.
  - `configure_docker_firewall` appends a marker-delimited `# BEGIN/END UFW AND DOCKER` block (ufw-docker's DOCKER-USER rules plus a `tailscale0` RETURN) to `/etc/ufw/after.rules`. Reruns delete the block with `sed` and append it again. If `ufw reload` fails, it restores `after.rules.pre-docker.bak`.
  - This step runs after the SSH gate, so a firewall mistake here cannot cause an SSH lockout.
- When the SSH port changes between runs, `configure_ufw_firewall` deletes the `tailscale0` rule for `PREVIOUS_SSH_PORT`, the port sshd used before the run. It is read in `prompt_ssh_port` before sshd_config is rewritten.

## Keep README in sync

README.md repeats much of what `setup.sh` writes: sshd_config, UFW rules, CrowdSec parser/acquis, sysctl modules, auditd rules, Caddy layout, automatic update schedule, swap sizing, prompts and defaults. If you change a generated config, a port, a default, or the order of prompts, update the matching README section too.
