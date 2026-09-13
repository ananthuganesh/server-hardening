#!/usr/bin/env bash

# ==============================================================================
# DEBIAN 13 HARDENED SETUP - PHASE 2: SYSTEM HARDENING (RUN AS SUDO)
# Optimized for Debian 13 (Trixie), Kernel 6.12, and a configurable admin user
# ==============================================================================

set -euo pipefail

# After the first run, login shells get umask 027 from this script, and sudo
# keeps it. Without resetting it, files rewritten on reruns (apt configs,
# banners, repo lists) would become unreadable to normal users and services.
umask 022

export DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"
export NEEDRESTART_MODE="${NEEDRESTART_MODE:-a}"

# Text Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Global Variables
TARGET_USER=""
TARGET_HOME=""
TARGET_PORT="2743"
HOSTNAME_VAL=""
LYNIS_TARGET_SCORE=83
SSH_ROLLBACK_UNIT="ssh-hardening-rollback"
SSH_ROLLBACK_SCRIPT="/root/ssh-hardening-rollback.sh"
SSH_ROLLBACK_DELAY_MINUTES=10
# Per-run snapshot restored by a rollback. /etc/ssh/sshd_config.bak (taken on
# the very first run) stays untouched as the original distro config.
SSH_PRE_RUN_CONFIG="/etc/ssh/sshd_config.pre-run"
UFW_PRE_RUN_DIR="/root/ufw-pre-run"
SSH_MIN_MODULI_BITS=3071
OS_ID=""
OS_VERSION_ID=""
OS_PRETTY=""

log_info() {
    printf "${BLUE}[INFO]${NC} %s\n" "$1"
}

log_success() {
    printf "${GREEN}[SUCCESS]${NC} %s\n" "$1"
}

log_warning() {
    printf "${YELLOW}[WARNING]${NC} %s\n" "$1"
}

log_error() {
    printf "${RED}[ERROR]${NC} %s\n" "$1" >&2
}

# Sets OS_* globals. Only Debian is supported; releases other than Debian 13
# (Trixie) need confirmation.
detect_os() {
    local continue_os

    if [ ! -r /etc/os-release ]; then
        log_error "Could not determine the operating system (/etc/os-release missing)."
        exit 1
    fi

    OS_ID="$(. /etc/os-release && printf '%s' "${ID:-}")"
    OS_VERSION_ID="$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")"
    OS_PRETTY="$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-unknown}")"

    if [ "$OS_ID" != "debian" ]; then
        log_error "Unsupported operating system: $OS_PRETTY. These scripts support Debian only."
        exit 1
    fi

    if [ "$OS_VERSION_ID" = "13" ]; then
        log_success "Verified OS: $OS_PRETTY"
    else
        log_warning "This script is optimized for Debian 13 (Trixie). Found: $OS_PRETTY"
        read -r -p "Do you want to continue anyway? (y/N): " continue_os
        if [[ ! "$continue_os" =~ ^[Yy]$ ]]; then
            log_error "Execution halted by user."
            exit 1
        fi
    fi
}

# Prints the comma-separated subset of the given algorithms that this OpenSSH
# build supports. An unknown algorithm name would make sshd -t fail, so this
# keeps the hardened config valid if the OpenSSH version changes.
filter_ssh_algorithms() {
    local query="$1"
    shift
    local supported
    local alg
    local selected=()

    supported="$(ssh -Q "$query" 2>/dev/null || true)"
    for alg in "$@"; do
        if grep -qxF "$alg" <<< "$supported"; then
            selected+=("$alg")
        fi
    done

    local IFS=,
    printf '%s' "${selected[*]:-}"
}

install_crowdsec_collection() {
    local collection="$1"

    if cscli collections install "$collection"; then
        log_success "CrowdSec collection '$collection' installed."
    else
        log_warning "CrowdSec collection '$collection' could not be installed or may already be installed; continuing."
    fi
}

cancel_ssh_rollback_timer() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop "${SSH_ROLLBACK_UNIT}.timer" "${SSH_ROLLBACK_UNIT}.service" >/dev/null 2>&1 || true
        systemctl reset-failed "${SSH_ROLLBACK_UNIT}.timer" "${SSH_ROLLBACK_UNIT}.service" >/dev/null 2>&1 || true
    fi
    rm -f "$SSH_ROLLBACK_SCRIPT"
}

schedule_ssh_rollback_timer() {
    log_warning "Arming automatic SSH rollback in ${SSH_ROLLBACK_DELAY_MINUTES} minutes until you confirm access works."

    if command -v systemd-run >/dev/null 2>&1; then
        cancel_ssh_rollback_timer
        cat << 'EOF' > "$SSH_ROLLBACK_SCRIPT"
#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/root/ssh-hardening-rollback.log"
{
    echo "$(date -Is) Automatic SSH rollback triggered."

    # Restore the state from just before this run (on a rerun that is the
    # already-hardened config), not the original distro config.
    if [ -f /etc/ssh/sshd_config.pre-run ]; then
        cp /etc/ssh/sshd_config.pre-run /etc/ssh/sshd_config
        echo "Restored /etc/ssh/sshd_config from the pre-run snapshot."
    elif [ -f /etc/ssh/sshd_config.bak ]; then
        cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
        echo "Restored /etc/ssh/sshd_config from the original backup."
    else
        echo "No sshd_config snapshot found; keeping current sshd_config."
    fi

    if command -v sshd >/dev/null 2>&1; then
        sshd -t || echo "Warning: restored sshd_config did not validate cleanly."
    fi

    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true

    if command -v ufw >/dev/null 2>&1; then
        if [ -f /root/ufw-pre-run/was-active ]; then
            cp /root/ufw-pre-run/user.rules /etc/ufw/user.rules 2>/dev/null || true
            cp /root/ufw-pre-run/user6.rules /etc/ufw/user6.rules 2>/dev/null || true
            ufw reload || true
            echo "UFW was active before this run; restored its previous rules."
        else
            ufw --force disable || true
            echo "UFW was not active before this run; disabled it for emergency access."
        fi
    fi

    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
    echo "Automatic SSH rollback completed."
} >> "$LOG_FILE" 2>&1
EOF
        chmod 700 "$SSH_ROLLBACK_SCRIPT"
        systemd-run \
            --unit="$SSH_ROLLBACK_UNIT" \
            --on-active="${SSH_ROLLBACK_DELAY_MINUTES}min" \
            "$SSH_ROLLBACK_SCRIPT" >/dev/null
        log_warning "If you do not confirm SSH access, rollback will restore old SSH settings and disable UFW."
    else
        log_error "systemd-run is unavailable; refusing to harden SSH without an automatic rollback timer."
        exit 1
    fi
}

perform_ssh_rollback_now() {
    local reason="$1"
    log_error "$reason"
    if [ -f "$SSH_PRE_RUN_CONFIG" ]; then
        cp "$SSH_PRE_RUN_CONFIG" /etc/ssh/sshd_config
    elif [ -f /etc/ssh/sshd_config.bak ]; then
        cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
    fi
    sshd -t || true
    systemctl restart ssh || systemctl restart sshd || true
    if command -v ufw >/dev/null 2>&1; then
        if [ -f "$UFW_PRE_RUN_DIR/was-active" ]; then
            log_info "Restoring the UFW rules from before this run..."
            cp "$UFW_PRE_RUN_DIR/user.rules" /etc/ufw/user.rules 2>/dev/null || true
            cp "$UFW_PRE_RUN_DIR/user6.rules" /etc/ufw/user6.rules 2>/dev/null || true
            ufw reload || true
        else
            log_info "Disabling UFW (it was not active before this run) to ensure you are not locked out..."
            ufw --force disable || true
        fi
    fi
    cancel_ssh_rollback_timer
    log_info "SSH rollback completed: SSH config and UFW are back to their state from before this run."
}

validate_linux_username() {
    local username="$1"
    [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && [ "$username" != "root" ]
}

# The admin user was already chosen in bootstrap.sh and setup.sh is started by
# that user with sudo, so take it from SUDO_USER instead of asking again. Only
# prompt when that is impossible (for example when started from a root shell).
resolve_target_user() {
    local username_input

    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] && validate_linux_username "$SUDO_USER"; then
        TARGET_USER="$SUDO_USER"
        log_info "Administrative user: '$TARGET_USER' (the account that ran sudo)."
    else
        log_warning "Could not detect the admin user from sudo; setup.sh should be run as: sudo ./setup.sh"
        while true; do
            read -r -p "Enter administrative username: " username_input
            TARGET_USER="$username_input"
            if validate_linux_username "$TARGET_USER"; then
                break
            fi
            log_error "Invalid username. Use lowercase letters, numbers, underscore, or hyphen; start with a letter/underscore; do not use root."
        done
    fi

    if ! id "$TARGET_USER" &>/dev/null; then
        log_error "User '$TARGET_USER' does not exist. Run bootstrap.sh first or choose an existing sudo user."
        exit 1
    fi

    if [ "$(id -u "$TARGET_USER")" -lt 1000 ]; then
        log_error "'$TARGET_USER' is a system account (UID below 1000) and cannot be the admin user."
        exit 1
    fi

    TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
    if [ -z "$TARGET_HOME" ] || [ ! -d "$TARGET_HOME" ]; then
        log_error "Could not determine home directory for '$TARGET_USER'."
        exit 1
    fi

    if ! id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx sudo; then
        log_error "User '$TARGET_USER' is not in the sudo group. Run bootstrap.sh first or add the user to sudo before hardening SSH."
        exit 1
    fi
}

# Phase 2 disables password SSH logins, so the admin must already have a key
# that sshd will accept. StrictModes makes sshd silently ignore keys when the
# home, ~/.ssh or authorized_keys are writable by other users.
check_admin_ssh_keys() {
    local ssh_dir="$TARGET_HOME/.ssh"
    local auth_keys="$ssh_dir/authorized_keys"

    if [ ! -s "$auth_keys" ] || ! ssh-keygen -l -f "$auth_keys" >/dev/null 2>&1; then
        log_error "No valid SSH public key found in $auth_keys."
        log_error "Phase 2 disables password logins, so '$TARGET_USER' would be locked out. Run bootstrap.sh first."
        exit 1
    fi

    chmod go-w "$TARGET_HOME"
    chown "$TARGET_USER:$TARGET_USER" "$ssh_dir" "$auth_keys"
    chmod 700 "$ssh_dir"
    chmod 600 "$auth_keys"
    log_success "SSH key(s) for '$TARGET_USER' found and permissions verified."
}

# Root gets locked in Phase 2, and provider emergency consoles log in with a
# password, not a key. Without a usable admin password there is no way back in
# if Tailscale or SSH ever breaks.
ensure_admin_password() {
    local password_status

    password_status="$(passwd -S "$TARGET_USER" 2>/dev/null | awk '{print $2}' || true)"
    if [ "$password_status" = "P" ]; then
        log_info "User '$TARGET_USER' has a password set (needed for sudo and the emergency console). Make sure it is saved in your password manager."
        return 0
    fi

    log_warning "User '$TARGET_USER' has no usable password. Root will be locked, and the provider's emergency console needs a password."
    until passwd "$TARGET_USER"; do
        log_warning "Password was not set; try again."
    done
}

# 1. Pre-Execution Checks
verify_environment() {
    log_info "Verifying execution context..."
    
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run with sudo! Run: sudo ./setup.sh"
        exit 1
    fi

    detect_os
    resolve_target_user
    check_admin_ssh_keys
    ensure_admin_password

    # Hostname and timezone are set in bootstrap.sh (Phase 1); Phase 2 only reads them.
    HOSTNAME_VAL="$(hostname -s)"
    log_info "Hostname: $HOSTNAME_VAL, timezone: $(timedatectl show -p Timezone --value 2>/dev/null || echo unknown) (change them by rerunning bootstrap.sh)"

    if [ "${SUDO_USER:-}" != "$TARGET_USER" ]; then
        log_warning "You are configuring admin user '$TARGET_USER', but sudo was started by '${SUDO_USER:-root}'."
        read -r -p "Are you sure you want to proceed? (y/N): " proceed_user
        if [[ ! "$proceed_user" =~ ^[Yy]$ ]]; then
            log_error "Execution halted."
            exit 1
        fi
    fi
    
    log_success "Execution context verified."
}

# 2. Base System Setup
configure_base_system() {
    printf "\n=== 1. Base System Setup ===\n"

    log_info "Configuring UTF-8 locale for terminal applications..."
    apt-get update
    apt-get install -y locales
    if grep -qE '^[#[:space:]]*en_US\.UTF-8[[:space:]]+UTF-8' /etc/locale.gen; then
        sed -i 's/^[#[:space:]]*en_US\.UTF-8[[:space:]]\+UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
    else
        echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen
    fi
    locale-gen en_US.UTF-8
    update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
    cat << 'EOF' > /etc/default/locale
LANG=en_US.UTF-8
LC_ALL=en_US.UTF-8
EOF
    if grep -q '^LANG=' /etc/environment 2>/dev/null; then
        sed -i 's/^LANG=.*/LANG=en_US.UTF-8/' /etc/environment
    else
        echo 'LANG=en_US.UTF-8' >> /etc/environment
    fi
    if grep -q '^LC_ALL=' /etc/environment 2>/dev/null; then
        sed -i 's/^LC_ALL=.*/LC_ALL=en_US.UTF-8/' /etc/environment
    else
        echo 'LC_ALL=en_US.UTF-8' >> /etc/environment
    fi

    log_info "Updating apt packages & installing baseline requirements..."
    apt-get update && apt-get upgrade -y && apt-get autoremove -y

    # Correct time is required for HTTPS certificates, Tailscale check mode and
    # usable logs. Minimal images sometimes ship without a time sync service.
    if [ "$(timedatectl show -p NTP --value 2>/dev/null || true)" != "yes" ]; then
        log_info "Enabling NTP time synchronization..."
        if ! grep -q "install ok installed" <<< "$(dpkg-query -W -f='${Status}' chrony 2>/dev/null || true)"; then
            apt-get install -y systemd-timesyncd
        fi
        timedatectl set-ntp true || log_warning "Could not enable NTP time sync; check: timedatectl status"
    fi

    log_info "Installing essential admin and diagnostics tools..."
    apt-get install -y \
      btop \
      htop \
      tmux \
      jq \
      curl \
      wget \
      git \
      nano \
      vim \
      less \
      unzip \
      zip \
      tar \
      rsync \
      ncdu \
      tree \
      lsof \
      psmisc \
      net-tools \
      dnsutils \
      traceroute \
      mtr-tiny \
      ripgrep \
      fd-find

    local bashrc="$TARGET_HOME/.bashrc"
    touch "$bashrc"
    chown "$TARGET_USER:$TARGET_USER" "$bashrc"
    if ! grep -q 'LC_ALL=en_US.UTF-8' "$bashrc"; then
        cat << 'EOF' >> "$bashrc"

# UTF-8 locale for terminal applications such as btop
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
EOF
        chown "$TARGET_USER:$TARGET_USER" "$bashrc"
    fi
    
    log_info "Ensuring rsyslog is installed..."
    apt-get install -y rsyslog
    systemctl enable --now rsyslog
    
    log_info "Configuring rsyslog traditional timestamp format..."
    # Uncomment RSYSLOG_TraditionalFileFormat if present
    if grep -q "#\$ActionFileDefaultTemplate RSYSLOG_TraditionalFileFormat" /etc/rsyslog.conf; then
        sed -i 's/#\$ActionFileDefaultTemplate RSYSLOG_TraditionalFileFormat/\$ActionFileDefaultTemplate RSYSLOG_TraditionalFileFormat/' /etc/rsyslog.conf
    elif ! grep -q "\$ActionFileDefaultTemplate RSYSLOG_TraditionalFileFormat" /etc/rsyslog.conf; then
        echo '$ActionFileDefaultTemplate RSYSLOG_TraditionalFileFormat' >> /etc/rsyslog.conf
    fi
    
    log_info "Routing SSH logs to auth.log..."
    cat << 'EOF' > /etc/rsyslog.d/ssh-auth.conf
if $programname == 'sshd' or $programname == 'sshd-session' then {
    action(type="omfile" file="/var/log/auth.log" Template="RSYSLOG_TraditionalFileFormat")
    stop
}
EOF
    systemctl restart rsyslog
    log_success "Base system setup and rsyslog configured."
}

# 3. Swap Configuration
configure_swap() {
    printf "\n=== 2. Swap Configuration ===\n"

    local mem_kb
    local mem_gb
    local target_swap_gb
    local target_swap_kb
    local active_swap_kb
    local non_swapfile_kb
    local swapfile_size_kb
    local swapfile_size_mb

    mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    mem_gb=$(((mem_kb + 1048575) / 1048576))

    if [ "$mem_gb" -le 2 ]; then
        target_swap_gb=2
    elif [ "$mem_gb" -le 8 ]; then
        target_swap_gb="$mem_gb"
    else
        target_swap_gb=8
    fi

    target_swap_kb=$((target_swap_gb * 1024 * 1024))
    active_swap_kb=$(awk 'NR > 1 {total += $3} END {print total + 0}' /proc/swaps)
    non_swapfile_kb=$(awk 'NR > 1 && $1 != "/swapfile" {total += $3} END {print total + 0}' /proc/swaps)

    log_info "Detected ${mem_gb}GB RAM; target swap size is ${target_swap_gb}GB."

    if [ "$active_swap_kb" -ge "$target_swap_kb" ]; then
        log_success "Existing active swap already meets or exceeds target size."
    else
        if grep -qE '^/swapfile[[:space:]]+' /proc/swaps; then
            log_info "Disabling current /swapfile before resizing..."
            swapoff /swapfile
            swapfile_size_kb=$((target_swap_kb - non_swapfile_kb))
        else
            swapfile_size_kb=$((target_swap_kb - active_swap_kb))
        fi

        if [ "$swapfile_size_kb" -le 0 ]; then
            log_success "Existing non-swapfile swap already satisfies the target."
        else
            swapfile_size_mb=$(((swapfile_size_kb + 1023) / 1024))
            log_info "Creating /swapfile with ${swapfile_size_mb}MB capacity..."
            if ! fallocate -l "${swapfile_size_mb}M" /swapfile; then
                log_warning "fallocate failed; falling back to dd. This may take a little longer."
                dd if=/dev/zero of=/swapfile bs=1M count="$swapfile_size_mb" status=progress
            fi

            chmod 600 /swapfile
            mkswap /swapfile
            swapon /swapfile
            log_success "Swapfile enabled at /swapfile (${swapfile_size_mb}MB)."
        fi
    fi

    if grep -qE '^/swapfile[[:space:]]+' /proc/swaps && ! grep -qE '^[[:space:]]*/swapfile[[:space:]]+' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi

    cat << 'EOF' > /etc/sysctl.d/60-swap.conf
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF
    sysctl -p /etc/sysctl.d/60-swap.conf

    log_info "Current swap status:"
    swapon --show
}

# 4. Tailscale Installation
install_tailscale() {
    printf "\n=== 3. Tailscale Setup ===\n"
    
    if command -v tailscale &>/dev/null; then
        log_info "Tailscale is already installed."
    else
        log_info "Installing Tailscale..."
        curl -fsSL https://tailscale.com/install.sh | sh
    fi
    
    log_info "Starting Tailscale and waiting for authentication..."
    log_warning "Please authenticate the server in the browser link printed below:"
    
    # --accept-routes=false: a subnet route advertised elsewhere in the tailnet
    # that overlaps this server's own network (for example a 10.x private/VPC
    # range) would pull its local traffic into Tailscale and cut it off.
    # On reruns the node is already logged in. "tailscale up" then refuses to run
    # unless every non-default setting is repeated, so change settings with
    # "tailscale set" instead.
    if [ "$(tailscale status --json 2>/dev/null | jq -r '.BackendState // empty' 2>/dev/null || true)" = "Running" ]; then
        log_info "Tailscale is already logged in; applying settings with tailscale set."
        if ! tailscale set --ssh --accept-dns=true --accept-routes=false; then
            log_error "tailscale set failed. Check: tailscale status"
            exit 1
        fi
    elif ! tailscale up --ssh --accept-dns=true --accept-routes=false; then
        log_error "tailscale up command failed! Please verify if tailscaled daemon is active."
        exit 1
    fi
    
    log_info "Waiting for Tailscale connection to become fully active (Max 2 minutes)..."
    local timeout=120
    local elapsed=0
    until tailscale status &>/dev/null; do
        if [ "$elapsed" -ge "$timeout" ]; then
            log_error "Tailscale activation timed out after 2 minutes! Setup halted."
            exit 1
        fi
        sleep 5
        elapsed=$((elapsed + 5))
        log_info "Still waiting for Tailscale activation (${elapsed}s/120s)..."
    done
    
    TAILSCALE_IP=$(tailscale ip -4 | tr -d '[:space:]')
    log_success "Tailscale active! Internal IP: $TAILSCALE_IP"

    check_tailscale_key_expiry
    remind_tailscale_ssh_policy
}

# --ssh keeps Tailscale SSH on port 22 of the Tailscale IP as an emergency path
# if sshd breaks. It is authorized by the tailnet policy, not sshd_config, so
# the policy must not allow logging in as root. That cannot be enforced from
# the server; remind the user where to set it.
remind_tailscale_ssh_policy() {
    log_warning "Tailscale SSH is enabled as an emergency login path (port 22 on the Tailscale IP)."
    log_warning "It ignores sshd_config (AllowUsers, key-only login, root lock). Your tailnet policy decides who gets in."
    log_warning "In the Tailscale admin console -> Access controls, make every \"ssh\" rule use: \"users\": [\"autogroup:nonroot\"] (no \"root\")."
}

tailscale_key_expiry() {
    tailscale status --json 2>/dev/null | jq -r '.Self.KeyExpiry // empty' 2>/dev/null || true
}

# SSH is reachable only through Tailscale after Phase 2. Tailscale node keys
# expire (180 days by default); when that happens the server silently leaves
# the tailnet and SSH is gone until someone uses the emergency console.
check_tailscale_key_expiry() {
    local key_expiry
    local answer

    if ! command -v jq >/dev/null 2>&1; then
        log_warning "jq is missing, so Tailscale key expiry could not be checked. Disable key expiry for this machine in the Tailscale admin console."
        return 0
    fi

    key_expiry="$(tailscale_key_expiry)"
    if [ -z "$key_expiry" ]; then
        log_success "Tailscale key expiry is disabled for this machine."
        return 0
    fi

    log_warning "======================================================================"
    log_warning "This server's Tailscale key EXPIRES on $key_expiry."
    log_warning "After that the server leaves Tailscale and SSH (Tailscale-only) becomes unreachable."
    log_warning "Fix: Tailscale admin console -> Machines -> $(hostname -s) -> '...' menu -> Disable key expiry."
    log_warning "======================================================================"
    read -r -p "Press Enter after disabling key expiry (or type skip to continue anyway): " answer
    if [ "$answer" = "skip" ]; then
        log_warning "Continuing with key expiry enabled. ~/check-health.sh will keep reporting it."
        return 0
    fi

    sleep 5
    key_expiry="$(tailscale_key_expiry)"
    if [ -z "$key_expiry" ]; then
        log_success "Tailscale key expiry is now disabled."
    else
        log_warning "Key expiry still shows $key_expiry (it can take a minute to sync). Verify it in the admin console."
    fi
}

prepare_ssh_host_keys() {
    local rsa_bits

    log_info "Ensuring Ed25519 and RSA host keys exist..."
    ssh-keygen -A

    rsa_bits="$(ssh-keygen -l -f /etc/ssh/ssh_host_rsa_key.pub 2>/dev/null | awk '{print $1}' || true)"
    if [[ "$rsa_bits" =~ ^[0-9]+$ ]] && [ "$rsa_bits" -lt 3072 ]; then
        log_warning "RSA host key is only ${rsa_bits} bits; regenerating a 4096-bit key (its fingerprint will change)."
        rm -f /etc/ssh/ssh_host_rsa_key /etc/ssh/ssh_host_rsa_key.pub
        ssh-keygen -q -t rsa -b 4096 -N "" -f /etc/ssh/ssh_host_rsa_key
    fi

    if [ -f /etc/ssh/moduli ]; then
        log_info "Removing Diffie-Hellman moduli smaller than 3072 bits..."
        if [ ! -f /etc/ssh/moduli.bak ]; then
            cp /etc/ssh/moduli /etc/ssh/moduli.bak
        fi
        awk -v min="$SSH_MIN_MODULI_BITS" '$5 >= min' /etc/ssh/moduli > /etc/ssh/moduli.tmp
        if [ -s /etc/ssh/moduli.tmp ]; then
            mv /etc/ssh/moduli.tmp /etc/ssh/moduli
            chmod 644 /etc/ssh/moduli
        else
            rm -f /etc/ssh/moduli.tmp
            log_warning "No strong moduli found; leaving /etc/ssh/moduli unchanged."
        fi
    fi
}

# 5. SSH Hardening with Verification Gate
configure_ssh_hardening() {
    printf "\n=== 4. SSH Hardening ===\n"

    # Pre-fetch Tailscale IP
    local ts_ip
    ts_ip=$(tailscale ip -4 | tr -d '[:space:]')

    if [ -z "$ts_ip" ]; then
        log_error "Could not retrieve Tailscale IP. Aborting SSH hardening to avoid lockout."
        exit 1
    fi

    if [ -f /etc/ssh/sshd_config.bak ]; then
        log_info "Existing sshd_config backup found at /etc/ssh/sshd_config.bak; preserving it."
    else
        log_info "Backing up existing sshd_config..."
        cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
    fi

    # Snapshot the live state for this run's rollback.
    cp -p /etc/ssh/sshd_config "$SSH_PRE_RUN_CONFIG"
    rm -rf "$UFW_PRE_RUN_DIR"
    mkdir -p "$UFW_PRE_RUN_DIR"
    chmod 700 "$UFW_PRE_RUN_DIR"
    if command -v ufw >/dev/null 2>&1 && grep -q '^Status: active' <<< "$(ufw status 2>/dev/null || true)"; then
        cp -p /etc/ufw/user.rules /etc/ufw/user6.rules "$UFW_PRE_RUN_DIR/" 2>/dev/null || true
        touch "$UFW_PRE_RUN_DIR/was-active"
    fi

    schedule_ssh_rollback_timer

    prepare_ssh_host_keys

    log_info "Selecting modern SSH algorithms supported by this OpenSSH build..."
    local kex
    local ciphers
    local macs
    local host_key_algorithms
    local host_key
    local crypto_config=""
    local host_key_config=""

    kex=$(filter_ssh_algorithms kex \
        mlkem768x25519-sha256 \
        sntrup761x25519-sha512 \
        sntrup761x25519-sha512@openssh.com \
        curve25519-sha256 \
        curve25519-sha256@libssh.org \
        diffie-hellman-group18-sha512 \
        diffie-hellman-group16-sha512 \
        diffie-hellman-group-exchange-sha256)
    ciphers=$(filter_ssh_algorithms cipher \
        chacha20-poly1305@openssh.com \
        aes256-gcm@openssh.com \
        aes128-gcm@openssh.com \
        aes256-ctr \
        aes192-ctr \
        aes128-ctr)
    macs=$(filter_ssh_algorithms mac \
        hmac-sha2-512-etm@openssh.com \
        hmac-sha2-256-etm@openssh.com \
        umac-128-etm@openssh.com)
    host_key_algorithms=$(filter_ssh_algorithms key-sig \
        ssh-ed25519 \
        ssh-ed25519-cert-v01@openssh.com \
        sk-ssh-ed25519@openssh.com \
        sk-ssh-ed25519-cert-v01@openssh.com \
        rsa-sha2-512 \
        rsa-sha2-512-cert-v01@openssh.com \
        rsa-sha2-256 \
        rsa-sha2-256-cert-v01@openssh.com)

    if [ -n "$kex" ]; then
        crypto_config+="KexAlgorithms $kex"$'\n'
    fi
    if [ -n "$ciphers" ]; then
        crypto_config+="Ciphers $ciphers"$'\n'
    fi
    if [ -n "$macs" ]; then
        crypto_config+="MACs $macs"$'\n'
    fi
    if [ -n "$host_key_algorithms" ]; then
        crypto_config+="HostKeyAlgorithms $host_key_algorithms"$'\n'
    fi
    if [ -z "$crypto_config" ]; then
        log_warning "Could not query supported SSH algorithms (ssh -Q); keeping OpenSSH default algorithms."
    fi

    for host_key in /etc/ssh/ssh_host_ed25519_key /etc/ssh/ssh_host_rsa_key; do
        if [ -f "$host_key" ]; then
            host_key_config+="HostKey $host_key"$'\n'
        fi
    done

    # Keep admins an earlier run already allowed, so running setup.sh as a
    # second admin never silently removes the first one from AllowUsers.
    local allow_users="$TARGET_USER"
    local existing_user
    if grep -qxF "port $TARGET_PORT" <<< "$(sshd -T 2>/dev/null || true)"; then
        while read -r existing_user; do
            if [ -n "$existing_user" ] && [ "$existing_user" != "$TARGET_USER" ] && id "$existing_user" &>/dev/null; then
                allow_users+=" $existing_user"
            fi
        done <<< "$(sshd -T 2>/dev/null | awk '$1 == "allowusers" {print $2}' || true)"
    fi
    log_info "SSH login will be allowed for: $allow_users"

    # Shown by sshd (Banner) and on the console. Replaces Debian's default,
    # which advertises the OS version before login.
    log_info "Writing unauthorized access login banners..."
    cat << 'EOF' > /etc/issue
Authorized access only. All activity is monitored and logged.
Unauthorized access is prohibited and will be prosecuted.
EOF
    cp /etc/issue /etc/issue.net
    chmod 644 /etc/issue /etc/issue.net

    log_info "Writing hardened SSH configuration..."
    cat << EOF > /etc/ssh/sshd_config
# Hardened OpenSSH Daemon Configuration (Debian 13)
#
# Do not bind sshd to the Tailscale IP with ListenAddress.
# On reboot, ssh can start before tailscale0 receives its IP, which makes
# port $TARGET_PORT refuse connections. UFW restricts this port to tailscale0.
#
# sshd uses the first value it reads for each keyword, so these settings win
# over anything in the sshd_config.d drop-ins included at the bottom.

Port $TARGET_PORT

# Host keys: Ed25519 and RSA (>= 3072 bits) only
${host_key_config}
# Modern key exchange, ciphers and MACs (filtered to what this OpenSSH supports)
${crypto_config}
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
AllowUsers $allow_users
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

# Include distro-managed sub-configurations
Include /etc/ssh/sshd_config.d/*.conf

Subsystem sftp /usr/lib/openssh/sftp-server
EOF

    # Defensive cleanup for reruns over older script versions.
    sed -i '/^[[:space:]]*ListenAddress[[:space:]]/d' /etc/ssh/sshd_config

    log_info "Validating configuration..."
    if ! sshd -t; then
        perform_ssh_rollback_now "sshd configuration validation failed. Rolling back config changes."
        exit 1
    fi

    local effective_config
    local expected_setting
    effective_config="$(sshd -T 2>/dev/null || true)"
    if [ -z "$effective_config" ]; then
        log_warning "Could not read the effective sshd configuration (sshd -T); skipping drop-in override check."
    else
        for expected_setting in "port $TARGET_PORT" "permitrootlogin no" "passwordauthentication no" "pubkeyauthentication yes"; do
            if ! grep -qxF "$expected_setting" <<< "$effective_config"; then
                perform_ssh_rollback_now "Effective sshd configuration is missing '$expected_setting' (check /etc/ssh/sshd_config.d/). Rolling back."
                exit 1
            fi
        done
    fi

    log_info "Restarting SSH service..."
    systemctl restart ssh
    if ! systemctl is-active --quiet ssh; then
        perform_ssh_rollback_now "SSH service is not active after restart. Rolling back immediately."
        exit 1
    fi
    if command -v ss >/dev/null 2>&1 && ! ss -ltn | awk -v port=":$TARGET_PORT" '$4 ~ port "$" {found=1} END {exit found ? 0 : 1}'; then
        perform_ssh_rollback_now "SSH is not listening on port $TARGET_PORT after restart. Rolling back immediately."
        exit 1
    fi
    
    # Configure UFW rules BEFORE prompt to allow the user to test UFW seamlessly
    configure_ufw_firewall "$ts_ip"

    log_warning "======================================================================"
    log_warning "                    SSH SAFETY VERIFICATION GATE                      "
    log_warning "======================================================================"
    log_warning "SSH has been moved to Port $TARGET_PORT."
    log_warning "Firewall access is restricted to the Tailscale interface only ($ts_ip)."
    log_warning "Do NOT close this current terminal session under any circumstances!"
    log_warning "Automatic rollback is armed for ${SSH_ROLLBACK_DELAY_MINUTES} minutes and will be cancelled only after you type yes."
    log_warning "ACTION REQUIRED:"
    log_warning "1. Ensure your local computer is connected to Tailscale."
    log_warning "2. Open a NEW terminal window on your local machine."
    log_warning "3. Test the hardened connection by running:"
    log_warning "   ssh -i ~/.ssh/$TARGET_USER-$HOSTNAME_VAL.pem -o IdentitiesOnly=yes -p $TARGET_PORT $TARGET_USER@$ts_ip"
    log_warning "   (Use the .pem file bootstrap.sh generated. IdentitiesOnly=yes matters: MaxAuthTries is 3.)"
    log_warning "   Your SSH client sees the Tailscale IP and port as a new host, so it will ask you to confirm the fingerprint."
    log_warning "======================================================================"
    
    while true; do
        read -r -p "Did the new SSH connection connect successfully? (yes/no): " ssh_success
        if [[ "$ssh_success" =~ ^[Yy][Ee][Ss]$ ]]; then
            cancel_ssh_rollback_timer
            # If the answer came after the rollback window, the timer has already
            # restored the old SSH config and disabled UFW; do not report success.
            if ! grep -qxF "port $TARGET_PORT" <<< "$(sshd -T 2>/dev/null || true)" || ! grep -q '^Status: active' <<< "$(ufw status 2>/dev/null || true)"; then
                log_error "The ${SSH_ROLLBACK_DELAY_MINUTES}-minute rollback already ran: SSH and UFW are back to their previous state."
                log_error "The server is NOT hardened. Rerun: sudo ./setup.sh (see /root/ssh-hardening-rollback.log)."
                exit 1
            fi
            log_success "SSH Hardening confirmed working. Proceeding."
            break
        elif [[ "$ssh_success" =~ ^[Nn][Oo]$ ]]; then
            perform_ssh_rollback_now "SSH verification failed. Rolling back config changes immediately."
            log_warning "Please debug Tailscale network connectivity before executing again."
            exit 1
        else
            log_warning "Please type 'yes' or 'no'."
        fi
    done
}

# 6. UFW Firewall Setup
configure_ufw_firewall() {
    local ts_ip=$1
    log_info "Installing and configuring UFW firewall..."
    apt-get install -y ufw
    
    # Verify tailscale0 interface exists
    if ! ip link show tailscale0 &>/dev/null; then
        log_warning "tailscale0 network interface was not detected by the OS. Waiting 5s..."
        sleep 5
    fi
    
    # Configure default rules
    ufw default deny incoming
    ufw default allow outgoing
    ufw default deny forward
    
    # Open standard web traffic
    ufw allow 80/tcp comment 'HTTP'
    ufw allow 443/tcp comment 'HTTPS'
    ufw allow 443/udp comment 'HTTP/3 (Caddy)'
    
    # Open port 2743 specifically on the tailscale0 interface
    ufw allow in on tailscale0 to any port "$TARGET_PORT" proto tcp comment 'SSH via Tailscale only'

    # Earlier versions of this script used port 2626; close it on reruns.
    if [ "$TARGET_PORT" != "2626" ]; then
        ufw delete allow in on tailscale0 to any port 2626 proto tcp >/dev/null 2>&1 || true
    fi

    log_info "Enabling UFW..."
    ufw --force enable
    
    log_info "UFW Status:"
    ufw status verbose
}

# 7. Lock down Root
lock_down_root() {
    printf "\n=== 5. Lock Down Root ===\n"
    log_info "Locking root password..."
    passwd -l root

    # Verify locked
    if grep -qE '^root:(!|\*)' /etc/shadow; then
        log_success "Root account successfully locked."
    else
        log_warning "Verify root lock failed. Shadow record does not start with ! or *."
    fi

    # With root locked, sulogin refuses to open systemd's emergency/rescue
    # shell, so a boot problem (bad fstab line, failed mount) would leave the
    # provider console with no shell at all. Allow it without a password: the
    # console is only reachable by someone already logged into the provider.
    log_info "Allowing the emergency/rescue boot shell on the console despite the locked root account..."
    local unit
    for unit in emergency rescue; do
        mkdir -p "/etc/systemd/system/${unit}.service.d"
        cat << 'EOF' > "/etc/systemd/system/${unit}.service.d/sulogin-force.conf"
# Managed by setup.sh: root is locked, so let sulogin start the shell anyway.
[Service]
Environment=SYSTEMD_SULOGIN_FORCE=1
EOF
    done
    systemctl daemon-reload
}

# 8. CrowdSec IPS Setup
configure_crowdsec() {
    printf "\n=== 6. CrowdSec IPS Setup ===\n"
    
    log_info "Installing CrowdSec official version..."
    curl -fsSL https://install.crowdsec.net | bash

    log_info "Installing CrowdSec engine..."
    apt-get update
    apt-get install -y crowdsec

    systemctl enable --now crowdsec

    log_info "Installing NFTables firewall bouncer..."
    if ! apt-get install -y crowdsec-firewall-bouncer-nftables; then
        log_warning "Bouncer package setup failed; attempting API key repair before retrying package configuration."
    fi

    local bouncer_config="/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml"
    if [ -f "$bouncer_config" ]; then
        log_info "Refreshing CrowdSec bouncer API key..."
        local bouncer_key
        cscli bouncers delete crowdsec-firewall-bouncer 2>/dev/null || true
        bouncer_key=$(cscli bouncers add crowdsec-firewall-bouncer -o raw)
        if grep -q '^api_key:' "$bouncer_config"; then
            sed -i "s|^api_key:.*|api_key: $bouncer_key|" "$bouncer_config"
        else
            echo "api_key: $bouncer_key" >> "$bouncer_config"
        fi
        if grep -q '^api_url:' "$bouncer_config"; then
            sed -i 's|^api_url:.*|api_url: http://127.0.0.1:8080/|' "$bouncer_config"
        else
            echo 'api_url: http://127.0.0.1:8080/' >> "$bouncer_config"
        fi
        dpkg --configure -a
    else
        log_warning "Bouncer config was not found at $bouncer_config; package configuration may be incomplete."
    fi

    systemctl restart crowdsec
    systemctl enable crowdsec-firewall-bouncer
    # A rerun replaces the bouncer API key; "enable --now" would leave an
    # already-running bouncer on the deleted key and bans would stop applying.
    systemctl restart crowdsec-firewall-bouncer
    
    log_info "Updating CrowdSec Hub..."
    cscli hub update
    
    log_info "Installing standard CrowdSec log detection collections..."
    install_crowdsec_collection crowdsecurity/linux
    install_crowdsec_collection crowdsecurity/sshd
    install_crowdsec_collection crowdsecurity/caddy
    
    log_info "Creating Debian 13 sshd-session parser..."
    mkdir -p /etc/crowdsec/parsers/s00-raw
    cat << 'EOF' > /etc/crowdsec/parsers/s00-raw/debian13-sshd-session.yaml
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
EOF

    # Admin SSH arrives from Tailscale (100.64.0.0/10), which the default
    # CrowdSec whitelist does not cover. A few failed key attempts would ban
    # the admin's Tailscale IP, and the nftables bouncer blocks it on every
    # interface, including tailscale0: a lockout.
    log_info "Whitelisting Tailscale addresses in CrowdSec..."
    mkdir -p /etc/crowdsec/parsers/s02-enrich
    cat << 'EOF' > /etc/crowdsec/parsers/s02-enrich/tailscale-whitelist.yaml
name: custom/tailscale-whitelist
description: "Never ban Tailscale addresses; admin SSH arrives from them"
whitelist:
  reason: "Tailscale admin network"
  cidr:
    - "100.64.0.0/10"
    - "fd7a:115c:a1e0::/48"
EOF

    # sshd logs reach CrowdSec once, through /var/log/auth.log (rsyslog). A
    # second journalctl source for ssh.service would count every failed login
    # twice and halve the ban threshold.
    log_info "Writing CrowdSec acquisition configuration..."
    # Caddy access log is a single JSON file; rolled copies are not listed so
    # CrowdSec never re-reads old lines.
    cat << 'EOF' > /etc/crowdsec/acquis.yaml
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
EOF


    log_info "Starting CrowdSec services..."
    systemctl restart crowdsec
    systemctl enable crowdsec

    # Lift bans on individual Tailscale IPs made before the whitelist loaded.
    # --contained matches decisions inside the range; without it only a ban on
    # the whole range itself would be deleted.
    cscli decisions delete --range 100.64.0.0/10 --contained >/dev/null 2>&1 || true
    cscli decisions delete --range fd7a:115c:a1e0::/48 --contained >/dev/null 2>&1 || true

    # Keep parsers and scenarios current (the package ships this timer but does
    # not always enable it).
    if systemctl cat crowdsec-hubupdate.timer >/dev/null 2>&1; then
        systemctl enable --now crowdsec-hubupdate.timer || log_warning "Could not enable crowdsec-hubupdate.timer."
    fi

    # Optional CrowdSec Console Enrollment
    printf "\n"
    log_info "CrowdSec Console Enrollment (Optional)"
    read -r -p "Enter your CrowdSec Console Enrollment Key (leave empty to skip): " CS_ENROLL_KEY
    if [ -n "$CS_ENROLL_KEY" ]; then
        log_info "Enrolling with CrowdSec Console..."
        if cscli console enroll "$CS_ENROLL_KEY"; then
            systemctl reload crowdsec || log_warning "CrowdSec reload after console enrollment failed; continuing."
            log_success "Successfully enrolled with CrowdSec Console!"
        else
            log_warning "CrowdSec Console enrollment failed or this instance is already enrolled; continuing."
        fi
    else
        log_info "Skipping CrowdSec Console enrollment."
    fi
    
    log_success "CrowdSec configured successfully."
}

# 9. Kernel Hardening
configure_kernel_hardening() {
    printf "\n=== 7. Kernel Hardening ===\n"
    
    log_info "Applying Sysctl hardening rules..."
    cat << 'EOF' > /etc/sysctl.d/99-hardening.conf
# IP Spoofing protection
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Ignore ICMP broadcast requests
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Disable source packet routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0

# Ignore send redirects
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Block redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# Log martians
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# SYN flood protection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 5

# IP forwarding is intentionally NOT disabled here: Docker needs it for
# container networking, and any later "sysctl --system" (package upgrades run
# it) would silently break all containers. Forwarded traffic is filtered by
# UFW (default deny forward) and the DOCKER-USER rules instead.

# Kernel pointer restriction
kernel.kptr_restrict = 2

# Disable SysRq
kernel.sysrq = 0

# Core dump security
kernel.core_uses_pid = 1
fs.suid_dumpable = 0

# Restrict dmesg
kernel.dmesg_restrict = 1

# Perf event restriction
kernel.perf_event_paranoid = 3

# BPF hardening
net.core.bpf_jit_harden = 2
kernel.unprivileged_bpf_disabled = 1

# Ptrace scope
kernel.yama.ptrace_scope = 1

# Filesystem protections
fs.protected_fifos = 2
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_regular = 2

# TTY line discipline
dev.tty.ldisc_autoload = 0

# Disable IPv6 if not needed (uncomment to disable)
# net.ipv6.conf.all.disable_ipv6 = 1
# net.ipv6.conf.default.disable_ipv6 = 1
EOF
    sysctl --system
    
    log_info "Blacklisting rare/unsecured kernel modules..."
    cat << 'EOF' > /etc/modprobe.d/blacklist-rare.conf
install usb-storage /bin/false
install firewire-ohci /bin/false
install dccp /bin/false
install sctp /bin/false
install rds /bin/false
install tipc /bin/false
EOF
    log_success "Kernel and module hardening rules configured."
}

# Automatic updates use Debian's unattended-upgrades on a fixed nightly timer
# instead of a raw cron job. unattended-upgrades takes the dpkg lock (so it
# never collides with a manual apt run), repairs interrupted dpkg runs,
# installs in small steps that survive power loss, and logs every run.
configure_automatic_updates() {
    log_info "Configuring automatic updates (Debian + Tailscale, Docker, CrowdSec, Caddy)..."

    cat << 'EOF' > /etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Enable "1";
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

    # Origins match the Origin/Label fields of each repository's Release file.
    cat << 'EOF' > /etc/apt/apt.conf.d/50unattended-upgrades
// Managed by setup.sh. Runs nightly via apt-daily-upgrade.timer.
Unattended-Upgrade::Origins-Pattern {
        // Debian stable point releases, updates and security fixes
        "origin=Debian,codename=${distro_codename},label=Debian";
        "origin=Debian,codename=${distro_codename}-updates";
        "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
        // Third-party repositories added by setup.sh
        "origin=Tailscale,label=Tailscale";
        "origin=Docker,label=Docker CE";
        "origin=packagecloud.io/crowdsec/crowdsec";
        "origin=cloudsmith/caddy/stable";
};

Unattended-Upgrade::Package-Blacklist {
};

// Never replace locally modified config files (sshd_config, UFW rules,
// Caddyfile, ...) with package defaults during an upgrade. An upgraded
// sshd_config reverting to port 22 would be a lockout.
Dpkg::Options {
        "--force-confdef";
        "--force-confold";
};

Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::InstallOnShutdown "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
// Reboots stay manual: ~/check-health.sh reports when one is needed.
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::SyslogEnable "true";
Unattended-Upgrade::SyslogFacility "daemon";
EOF

    # Fixed maintenance window in the server's time zone instead of the
    # default random daytime slot.
    mkdir -p /etc/systemd/system/apt-daily.timer.d /etc/systemd/system/apt-daily-upgrade.timer.d
    cat << 'EOF' > /etc/systemd/system/apt-daily.timer.d/override.conf
# Managed by setup.sh: refresh package lists before the nightly upgrade window.
[Timer]
OnCalendar=
OnCalendar=*-*-* 02:30
RandomizedDelaySec=30m
Persistent=true
EOF
    cat << 'EOF' > /etc/systemd/system/apt-daily-upgrade.timer.d/override.conf
# Managed by setup.sh: install updates at night. Persistent=false so a missed
# window is skipped rather than run right after a daytime boot.
[Timer]
OnCalendar=
OnCalendar=*-*-* 03:30
RandomizedDelaySec=15m
Persistent=false
EOF

    # Restart services still running old libraries after an update, so fixes
    # actually take effect. SSH sessions survive an sshd restart, and Docker
    # containers keep running thanks to live-restore.
    mkdir -p /etc/needrestart/conf.d
    cat << 'EOF' > /etc/needrestart/conf.d/50-setup-autorestart.conf
# Managed by setup.sh
$nrconf{restart} = 'a';
EOF

    systemctl daemon-reload
    systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
    log_success "Automatic updates scheduled nightly at 03:30 (server time)."
}

# Runs after all repositories exist, to catch origin or config mistakes now
# rather than discovering weeks later that nothing was being updated.
verify_automatic_updates() {
    printf "\n=== Automatic Update Check ===\n"

    local policy
    local origin
    local dry_run_output
    local problems=0

    # Every third-party origin in 50unattended-upgrades must match a configured
    # repository, or that software silently never updates.
    policy="$(LC_ALL=C apt-cache policy 2>/dev/null || true)"
    for origin in Debian Tailscale Docker packagecloud.io/crowdsec/crowdsec cloudsmith/caddy/stable; do
        if grep -qF "o=$origin," <<< "$policy"; then
            log_success "Automatic updates cover repository origin '$origin'."
        else
            log_warning "No repository with origin '$origin' found; its packages will NOT update automatically."
            problems=$((problems + 1))
        fi
    done

    log_info "Running unattended-upgrade --dry-run (may take a minute)..."
    dry_run_output="$(timeout 600 unattended-upgrade --dry-run --debug 2>&1)" || {
        log_warning "unattended-upgrade --dry-run exited with an error."
        problems=$((problems + 1))
    }
    if grep -qE '^(Traceback|E: |ERROR)' <<< "$dry_run_output"; then
        grep -m 3 -E '^(Traceback|E: |ERROR)' <<< "$dry_run_output"
        problems=$((problems + 1))
    fi

    if [ "$problems" -eq 0 ]; then
        log_success "Automatic updates are configured correctly."
    else
        log_warning "Automatic updates need attention. Check: sudo unattended-upgrade --dry-run --debug"
    fi
}

# 10. Security Packages & auditd Rules
configure_security_packages() {
    printf "\n=== 8. Security Packages & Auditing ===\n"
    
    log_info "Installing security monitoring packages..."
    apt-get install -y \
      libpam-tmpdir \
      libpam-pwquality \
      cracklib-runtime \
      apparmor \
      apparmor-utils \
      unattended-upgrades \
      cron \
      apt-listbugs \
      apt-listchanges \
      needrestart \
      debsums \
      apt-show-versions \
      auditd \
      acct \
      sysstat \
      rkhunter \
      lynis

    log_info "Enabling AppArmor mandatory access control..."
    if systemctl list-unit-files apparmor.service &>/dev/null; then
        systemctl enable --now apparmor || log_warning "AppArmor service could not be started automatically."
    else
        log_warning "AppArmor service unit not found after install."
    fi

    configure_automatic_updates
    systemctl enable --now unattended-upgrades || log_warning "unattended-upgrades service could not be started automatically."
    systemctl enable --now cron || log_warning "cron service could not be started automatically."

    log_info "Configuring auditd hardening rules..."
    systemctl enable --now auditd || log_warning "auditd service could not be enabled immediately; continuing after writing rules."
    cat << 'EOF' > /etc/audit/rules.d/hardening.rules
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
EOF
    printf -- '-w %s -p wa -k ssh_keys\n' "$TARGET_HOME/.ssh/authorized_keys" >> /etc/audit/rules.d/hardening.rules
    # 32-bit syscalls bypass arch=b64 rules on x86_64. Kept last: if the kernel
    # rejects it, the rules above are already loaded.
    if [ "$(uname -m)" = "x86_64" ]; then
        echo '-a always,exit -F arch=b32 -S execve -F euid=0 -k root_commands' >> /etc/audit/rules.d/hardening.rules
    fi
    augenrules --load || log_warning "auditd rules could not be loaded immediately; they will be retried by auditd on restart."
    systemctl restart auditd || service auditd restart || log_warning "auditd restart failed; continuing with installed rules."

    log_info "Enabling sysstat..."
    sed -i 's/ENABLED="false"/ENABLED="true"/' /etc/default/sysstat
    systemctl enable --now sysstat
    
    log_info "Enabling weekly debsums checks..."
    if [ -f /etc/default/debsums ]; then
        if grep -q '^CRON_CHECK=' /etc/default/debsums; then
            sed -i 's/^CRON_CHECK=.*/CRON_CHECK=weekly/' /etc/default/debsums
        else
            echo "CRON_CHECK=weekly" >> /etc/default/debsums
        fi
    else
        echo "CRON_CHECK=weekly" > /etc/default/debsums
    fi
    
    log_info "Hardening login definitions in /etc/login.defs..."
    sed -i 's/^UMASK.*/UMASK 027/' /etc/login.defs
    
    # Append high rounds and passwords durations if not already present
    for entry in "SHA_CRYPT_MIN_ROUNDS 10000" "SHA_CRYPT_MAX_ROUNDS 65536" "PASS_MAX_DAYS 365" "PASS_MIN_DAYS 1" "PASS_WARN_AGE 14"; do
        key=$(echo "$entry" | cut -d' ' -f1)
        if grep -q "^$key" /etc/login.defs; then
            sed -i "s|^$key.*|$entry|" /etc/login.defs
        else
            echo "$entry" >> /etc/login.defs
        fi
    done

    log_info "Configuring PAM password quality policy..."
    cat << 'EOF' > /etc/security/pwquality.conf
minlen = 14
minclass = 3
maxrepeat = 3
retry = 3
dictcheck = 1
usercheck = 1
enforcing = 1
EOF
    if ! grep -q 'pam_pwquality.so' /etc/pam.d/common-password; then
        sed -i '/pam_unix\.so/i password requisite pam_pwquality.so retry=3' /etc/pam.d/common-password
    fi

    log_info "Disabling core dumps..."
    cat << 'EOF' > /etc/security/limits.d/99-disable-core-dumps.conf
* soft core 0
* hard core 0
EOF
    mkdir -p /etc/systemd/coredump.conf.d
    cat << 'EOF' > /etc/systemd/coredump.conf.d/99-disable.conf
[Coredump]
Storage=none
ProcessSizeMax=0
EOF
    systemctl daemon-reload

    log_info "Setting secure default umask for login shells..."
    cat << 'EOF' > /etc/profile.d/99-secure-umask.sh
umask 027
EOF
    chmod 644 /etc/profile.d/99-secure-umask.sh

    log_info "Updating rkhunter baseline where possible..."
    rkhunter --update || log_warning "rkhunter update failed; continuing."
    rkhunter --propupd || log_warning "rkhunter property baseline update failed; continuing."
    
    log_info "Applying file permission hardening on system files..."
    [ -f /etc/ssh/sshd_config ] && chmod 600 /etc/ssh/sshd_config
    [ -f /etc/crontab ] && chmod 600 /etc/crontab
    [ -f /etc/at.deny ] && chmod 600 /etc/at.deny
    for cron_dir in /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/cron.monthly; do
        [ -d "$cron_dir" ] && chmod 700 "$cron_dir"
    done
    
    log_success "Security and audit packaging completed with Lynis ${LYNIS_TARGET_SCORE}+ target controls."
}

# 11. Caddy Web Server Setup
# Servers set up by earlier versions of this script run Nginx, which holds
# ports 80/443. Returns 1 when the user chooses to keep Nginx.
retire_nginx() {
    local custom_sites
    local answer

    if ! grep -q "install ok installed" <<< "$(dpkg-query -W -f='${Status}' nginx 2>/dev/null || true)"; then
        return 0
    fi

    custom_sites="$(find /etc/nginx/sites-enabled /etc/nginx/conf.d -mindepth 1 ! -name default 2>/dev/null || true)"
    if [ -n "$custom_sites" ]; then
        log_warning "Nginx has site configs that this script did not create:"
        printf '%s\n' "$custom_sites"
        log_warning "Switching to Caddy stops Nginx; those sites go offline until they are moved to /etc/caddy/sites/."
        read -r -p "Stop Nginx and switch to Caddy now? (y/N): " answer
        if [[ ! "$answer" =~ ^[Yy]$ ]]; then
            log_warning "Keeping Nginx and skipping Caddy. Rerun setup.sh after migrating the sites."
            return 1
        fi
    fi

    log_info "Stopping and disabling Nginx (package and /etc/nginx are kept; remove later with: sudo apt purge nginx)..."
    systemctl disable --now nginx || true
}

install_caddy() {
    log_info "Adding Caddy's official package repository..."
    apt-get install -y curl gnupg
    curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg --yes
    chmod 644 /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main" > /etc/apt/sources.list.d/caddy-stable.list
    chmod 644 /etc/apt/sources.list.d/caddy-stable.list

    log_info "Installing Caddy..."
    apt-get update
    apt-get install -y caddy
}

configure_caddy() {
    printf "\n=== 9. Caddy Web Server Setup ===\n"

    if ! retire_nginx; then
        return 0
    fi

    install_caddy

    # QUIC (HTTP/3) needs larger UDP buffers than the kernel default.
    cat << 'EOF' > /etc/sysctl.d/60-caddy-quic.conf
net.core.rmem_max = 7500000
net.core.wmem_max = 7500000
EOF
    sysctl -p /etc/sysctl.d/60-caddy-quic.conf

    log_info "Writing default site..."
    mkdir -p /var/www/html
    chmod 755 /var/www /var/www/html
    # Only replace the page this script created, never a deployed index.html.
    if [ ! -f /var/www/html/index.html ] || grep -q 'setup.sh default page' /var/www/html/index.html; then
        cat << EOF > /var/www/html/index.html
<!doctype html>
<!-- setup.sh default page -->
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Server online</title>
  <style>
    body { font-family: sans-serif; margin: 3rem; line-height: 1.5; color: #111; }
  </style>
</head>
<body>
  <h1>Server online</h1>
  <p>No site is configured for this address.</p>
</body>
</html>
EOF
    fi
    # The login umask is 027; Caddy runs as the caddy user and must read this.
    chmod 644 /var/www/html/index.html

    # Access log must be owned by caddy before anything opens it as root.
    install -d -m 750 -o caddy -g caddy /var/log/caddy
    touch /var/log/caddy/access.log
    chown caddy:caddy /var/log/caddy/access.log

    # Your own sites live in /etc/caddy/sites/*.caddy so reruns never touch
    # them. setgid + group caddy keeps files created with umask 027 readable.
    install -d -m 2750 -o root -g caddy /etc/caddy/sites
    if [ ! -f /etc/caddy/sites/README.caddy ]; then
        cat << 'EOF' > /etc/caddy/sites/README.caddy
# Add one file per site in this directory, named <something>.caddy.
# Caddy gets and renews HTTPS certificates automatically for real domain names
# (DNS must point to this server; ports 80 and 443 must be reachable).
#
# Reverse proxy to a Docker container published on localhost
# (docker run -p 3000:80 ... binds 127.0.0.1:3000). Avoid port 8080:
# CrowdSec's local API already uses 127.0.0.1:8080.
#
# example.com {
# 	import site_defaults
# 	reverse_proxy 127.0.0.1:3000
# }
#
# Static files:
#
# static.example.com {
# 	import site_defaults
# 	root * /var/www/static.example.com
# 	file_server
# }
#
# Apply changes: sudo caddy validate --config /etc/caddy/Caddyfile && sudo systemctl reload caddy
EOF
        chgrp caddy /etc/caddy/sites/README.caddy
        chmod 640 /etc/caddy/sites/README.caddy
    fi

    log_info "Writing /etc/caddy/Caddyfile..."
    cat << 'EOF' > /etc/caddy/Caddyfile.new
# Managed by setup.sh: reruns overwrite this file.
# Put your own sites in /etc/caddy/sites/*.caddy (see README.caddy there).

# Shared settings; add "import site_defaults" to every site.
(site_defaults) {
	encode zstd gzip
	header {
		# Browsers ignore HSTS on plain HTTP, so this only affects HTTPS sites.
		# No includeSubDomains: a subdomain served elsewhere over HTTP would break.
		Strict-Transport-Security "max-age=31536000"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}
	# JSON access log, read by CrowdSec (crowdsecurity/caddy).
	log {
		output file /var/log/caddy/access.log {
			roll_size 50MiB
			roll_keep 5
		}
		format json
	}
	# Hide dotfiles such as .git and .env, but keep ACME/.well-known working.
	@hidden {
		path */.*
		not path /.well-known/*
	}
	respond @hidden 404
}

# Default site for requests that match no domain (plain HTTP on the IP).
:80 {
	import site_defaults
	respond /health "ok" 200
	root * /var/www/html
	file_server
}

import /etc/caddy/sites/*.caddy
EOF
    chmod 644 /etc/caddy/Caddyfile.new

    # Validate as the caddy user so nothing it opens ends up owned by root.
    if runuser -u caddy -- env HOME=/var/lib/caddy caddy validate --config /etc/caddy/Caddyfile.new --adapter caddyfile; then
        mv /etc/caddy/Caddyfile.new /etc/caddy/Caddyfile
    else
        rm -f /etc/caddy/Caddyfile.new
        log_warning "The Caddy configuration failed validation (check /etc/caddy/sites/*.caddy); keeping the current Caddyfile."
    fi

    systemctl enable caddy
    systemctl reload-or-restart caddy

    if curl -fsS --max-time 5 http://127.0.0.1/health >/dev/null; then
        log_success "Caddy is serving the default site on port 80 (/health returns ok)."
    else
        log_warning "Caddy did not answer on http://127.0.0.1/health. Check: sudo journalctl -u caddy -n 50"
    fi

    # CrowdSec started before the Caddy log existed; restart so it tails it.
    if command -v cscli >/dev/null 2>&1; then
        systemctl restart crowdsec || log_warning "CrowdSec restart failed; it may not be reading the Caddy log yet."
    fi
}

# 12. Docker Setup
install_docker_engine() {
    log_info "Installing Docker Engine dependencies..."
    apt-get update && apt-get install -y ca-certificates curl gnupg

    log_info "Adding Docker's official GPG key..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
    chmod a+r /etc/apt/keyrings/docker.gpg

    log_info "Adding Docker official repository..."
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null

    log_info "Installing Docker Engine and Compose plugin packages..."
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
}

write_docker_daemon_config() {
    local daemon_json="/etc/docker/daemon.json"

    log_info "Writing hardened Docker daemon configuration..."
    mkdir -p /etc/docker
    if [ -f "$daemon_json" ] && [ ! -f "$daemon_json.bak" ]; then
        cp "$daemon_json" "$daemon_json.bak"
    fi

    # ip: publish container ports on 127.0.0.1 unless a host IP is given
    #     explicitly (-p 0.0.0.0:3000:80), so nothing is public by accident.
    # icc: containers on the default bridge cannot talk to each other.
    # no-new-privileges: setuid binaries inside containers cannot escalate.
    # live-restore: containers keep running while dockerd restarts/upgrades.
    cat << 'EOF' > "$daemon_json.new"
{
  "iptables": true,
  "ip6tables": true,
  "ip": "127.0.0.1",
  "icc": false,
  "no-new-privileges": true,
  "live-restore": true,
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF

    if dockerd --help 2>/dev/null | grep -- '--validate' >/dev/null && ! dockerd --validate --config-file "$daemon_json.new"; then
        log_warning "Docker rejected the hardened daemon.json; keeping the existing configuration."
        rm -f "$daemon_json.new"
    else
        mv "$daemon_json.new" "$daemon_json"
    fi

    if ! systemctl restart docker; then
        log_warning "Docker failed to restart with the hardened daemon.json; restoring the previous configuration."
        if [ -f "$daemon_json.bak" ]; then
            cp "$daemon_json.bak" "$daemon_json"
        else
            rm -f "$daemon_json"
        fi
        systemctl restart docker
    fi
    systemctl enable docker
}

# Docker publishes ports with DNAT rules that are evaluated before UFW's
# chains, so "ufw deny" does not protect containers. These DOCKER-USER rules
# (based on github.com/chaifeng/ufw-docker) drop new connections from public
# networks to containers unless allowed with "ufw route allow".
configure_docker_firewall() {
    local after_rules="/etc/ufw/after.rules"

    if ! command -v ufw >/dev/null 2>&1 || [ ! -f "$after_rules" ]; then
        log_warning "UFW is not installed; skipping Docker firewall integration."
        return 0
    fi

    log_info "Stopping Docker-published ports from bypassing UFW..."
    cp "$after_rules" "$after_rules.pre-docker.bak"
    sed -i '/^# BEGIN UFW AND DOCKER$/,/^# END UFW AND DOCKER$/d' "$after_rules"
    cat << 'EOF' >> "$after_rules"
# BEGIN UFW AND DOCKER
*filter
:ufw-user-forward - [0:0]
:ufw-docker-logging-deny - [0:0]
:DOCKER-USER - [0:0]
-A DOCKER-USER -j ufw-user-forward

-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
-A DOCKER-USER -m conntrack --ctstate INVALID -j DROP
-A DOCKER-USER -i docker0 -o docker0 -j ACCEPT

-A DOCKER-USER -j RETURN -s 10.0.0.0/8
-A DOCKER-USER -j RETURN -s 172.16.0.0/12
-A DOCKER-USER -j RETURN -s 192.168.0.0/16
-A DOCKER-USER -i tailscale0 -j RETURN

-A DOCKER-USER -p udp -m udp --sport 53 --dport 1024:65535 -j RETURN

-A DOCKER-USER -j ufw-docker-logging-deny -p tcp -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -d 192.168.0.0/16
-A DOCKER-USER -j ufw-docker-logging-deny -p tcp -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -d 10.0.0.0/8
-A DOCKER-USER -j ufw-docker-logging-deny -p tcp -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -d 172.16.0.0/12
-A DOCKER-USER -j ufw-docker-logging-deny -p udp -m udp --dport 0:32767 -d 192.168.0.0/16
-A DOCKER-USER -j ufw-docker-logging-deny -p udp -m udp --dport 0:32767 -d 10.0.0.0/8
-A DOCKER-USER -j ufw-docker-logging-deny -p udp -m udp --dport 0:32767 -d 172.16.0.0/12

-A DOCKER-USER -j RETURN

-A ufw-docker-logging-deny -m limit --limit 3/min --limit-burst 10 -j LOG --log-prefix "[UFW DOCKER BLOCK] "
-A ufw-docker-logging-deny -j DROP

COMMIT
# END UFW AND DOCKER
EOF

    if ufw reload; then
        log_success "Docker containers are now behind UFW. Expose one publicly with: ufw route allow proto tcp from any to any port CONTAINER_PORT"
    else
        log_warning "UFW rejected the Docker rules; restoring the previous after.rules."
        cp "$after_rules.pre-docker.bak" "$after_rules"
        ufw reload || log_warning "UFW reload with the restored rules also failed; check: ufw status verbose"
    fi
}

configure_docker() {
    printf "\n=== 10. Docker Configuration ===\n"

    if command -v docker &>/dev/null && docker compose version &>/dev/null; then
        log_info "Docker Engine and Compose plugin are already installed."
    else
        install_docker_engine
    fi

    log_info "Adding '$TARGET_USER' to docker group..."
    usermod -aG docker "$TARGET_USER"

    write_docker_daemon_config
    configure_docker_firewall

    log_success "Docker Engine configured successfully."
}

# 13. GitHub Deploy Key Helper
# GitHub accepts a deploy key on only one repository, so there is no shared
# server key. Instead install a helper that creates one key and one SSH host
# alias per project when that project is deployed.
install_github_deploy_key_helper() {
    printf "\n=== 11. GitHub Deploy Key Helper ===\n"

    local ssh_dir="$TARGET_HOME/.ssh"
    local helper="$TARGET_HOME/github-deploy-key.sh"

    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"
    chown "$TARGET_USER:$TARGET_USER" "$ssh_dir"

    cat << 'HELPER' > "$helper"
#!/usr/bin/env bash
# Creates a GitHub deploy key for ONE repository plus an SSH host alias for it.
# GitHub allows each deploy key on a single repository, so every project gets
# its own key.
#
# Usage: ~/github-deploy-key.sh OWNER/REPO

set -euo pipefail

# Published at https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints
GITHUB_ED25519_FINGERPRINT="SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU"

if [ "$EUID" -eq 0 ]; then
    echo "Run this as the user that deploys the project, not with sudo." >&2
    exit 1
fi

repo="${1:-}"
repo="${repo%.git}"
if [[ ! "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    echo "Usage: $0 OWNER/REPO   (for example: $0 acme/website)" >&2
    exit 1
fi

owner="${repo%%/*}"
name="${repo#*/}"
host_alias="github-${owner}-${name}"
ssh_dir="$HOME/.ssh"
key_file="$ssh_dir/deploy_${owner}_${name}"
ssh_config="$ssh_dir/config"
known_hosts="$ssh_dir/known_hosts"

mkdir -p "$ssh_dir"
chmod 700 "$ssh_dir"

if [ -f "$key_file" ]; then
    echo "Reusing existing deploy key $key_file"
else
    ssh-keygen -q -t ed25519 -N "" -C "deploy:${repo}@$(hostname -s)" -f "$key_file"
fi
chmod 600 "$key_file"

touch "$ssh_config"
chmod 600 "$ssh_config"
if ! grep -qxF "Host $host_alias" "$ssh_config"; then
    cat << CONFIG >> "$ssh_config"

Host $host_alias
    HostName github.com
    User git
    IdentityFile $key_file
    IdentitiesOnly yes
CONFIG
fi

# Pin GitHub's host key instead of trusting whatever answers first.
touch "$known_hosts"
chmod 644 "$known_hosts"
if ! ssh-keygen -F github.com -f "$known_hosts" >/dev/null; then
    scanned_key="$(ssh-keyscan -t ed25519 github.com 2>/dev/null | grep -v '^#' || true)"
    if [ -z "$scanned_key" ] || ! ssh-keygen -lf - <<< "$scanned_key" | grep -qF "$GITHUB_ED25519_FINGERPRINT"; then
        echo "GitHub's SSH host key did not match the published fingerprint; refusing to trust it." >&2
        exit 1
    fi
    printf '%s\n' "$scanned_key" >> "$known_hosts"
fi

printf "\n1. Open https://github.com/%s/settings/keys and click 'Add deploy key'.\n" "$repo"
printf "2. Title: %s. Leave 'Allow write access' unchecked unless this server must push.\n" "$(hostname -s)"
printf "3. Paste this public key:\n\n"
cat "$key_file.pub"
printf "\n"

read -r -p "Press Enter after adding the key to test it (or type skip): " answer
if [ "$answer" != "skip" ]; then
    set +e
    output="$(ssh -o BatchMode=yes -T "git@$host_alias" 2>&1)"
    set -e
    printf '%s\n' "$output"
    if [[ "$output" == *"successfully authenticated"* ]]; then
        echo "Deploy key works."
    else
        echo "Authentication did not succeed yet. Check the key on GitHub, then test with: ssh -T git@$host_alias" >&2
    fi
fi

printf "\nClone:              git clone git@%s:%s.git\n" "$host_alias" "$repo"
printf "Existing checkout:  git remote set-url origin git@%s:%s.git\n" "$host_alias" "$repo"
HELPER

    chmod 700 "$helper"
    chown "$TARGET_USER:$TARGET_USER" "$helper"
    log_success "Deploy key helper installed. For each project run: ~/github-deploy-key.sh OWNER/REPO"

    if [ -f "$ssh_dir/github" ]; then
        log_warning "A shared ~/.ssh/github key from an earlier version of this script still exists."
        log_warning "Once every project uses its own deploy key, remove it from GitHub and delete ~/.ssh/github*, the 'Host github.com' block in ~/.ssh/config, and the ssh-agent lines in ~/.bashrc."
    fi
}

# 14. Creating Health Check Utilities
create_health_check() {
    printf "\n=== 12. Installing Health Check Scripts ===\n"
    
    local user_home="$TARGET_HOME"
    local hc_script="$user_home/check-health.sh"
    
    cat << 'EOF' > "$hc_script"
#!/bin/bash
# System and Security Performance Diagnostic Script

# Text Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Hardened Server Health Diagnostic ===${NC}"

echo -e "\n${YELLOW}1. Docker Container Statuses:${NC}"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

echo -e "\n${YELLOW}2. Storage Volume Usage:${NC}"
df -h /

echo -e "\n${YELLOW}3. RAM and Swap Usage Metrics:${NC}"
free -h
swapon --show

echo -e "\n${YELLOW}4. CrowdSec IPS Active Bans:${NC}"
if command -v cscli &>/dev/null; then
    sudo cscli decisions list
else
    echo "Crowdsec cscli utility not found."
fi

echo -e "\n${YELLOW}5. SSH Audit (Failed / Invalid Inbound Attempts, Last Hour):${NC}"
sudo journalctl -u ssh --since "1 hour ago" | grep -iE "invalid|failed" | tail -10 || echo "No failed attempts detected."

echo -e "\n${YELLOW}6. Caddy Web Server Health:${NC}"
systemctl is-active caddy 2>/dev/null || echo "Caddy is not active."
curl -fsS http://127.0.0.1/health 2>/dev/null && echo || echo "Caddy health endpoint unavailable."

echo -e "\n${YELLOW}7. Automatic Updates:${NC}"
systemctl list-timers apt-daily-upgrade.timer --no-pager 2>/dev/null | head -n 2
if sudo test -f /var/log/unattended-upgrades/unattended-upgrades.log; then
    echo "Last run:"
    sudo tail -n 3 /var/log/unattended-upgrades/unattended-upgrades.log
else
    echo "No automatic update has run yet."
fi

echo -e "\n${YELLOW}8. Tailscale (only path for SSH):${NC}"
if tailscale status --peers=false >/dev/null 2>&1; then
    echo "Tailscale is connected: $(tailscale ip -4 2>/dev/null)"
    key_expiry="$(tailscale status --json 2>/dev/null | jq -r '.Self.KeyExpiry // empty' 2>/dev/null)"
    if [ -n "$key_expiry" ]; then
        echo -e "${RED}Node key expires on $key_expiry. Disable key expiry in the Tailscale admin console or SSH will stop working then.${NC}"
    else
        echo "Node key expiry is disabled."
    fi
else
    echo -e "${RED}Tailscale is NOT connected. SSH is only reachable through Tailscale.${NC}"
fi

echo -e "\n${YELLOW}9. Reboot Requirement:${NC}"
if [ -f /var/run/reboot-required ]; then
    cat /var/run/reboot-required
else
    echo "No reboot-required marker found."
fi

echo -e "\n${YELLOW}10. Lynis Hardening Index:${NC}"
if [ -f /var/log/lynis-report.dat ]; then
    sudo awk -F= '/^hardening_index=/ {print "Hardening index: " $2 "/100"; found=1} END {if (!found) print "Hardening index not found in report."}' /var/log/lynis-report.dat
else
    echo "No Lynis report found yet. Run: sudo lynis audit system --quick"
fi

EOF

    chmod +x "$hc_script"
    chown "$TARGET_USER:$TARGET_USER" "$hc_script"
    log_success "Diagnostic utility written to $hc_script."
}

# 15. Lynis Audit
run_lynis_audit() {
    printf "\n=== 13. System Security Auditing (Lynis) ===\n"
    
    log_info "Triggering baseline security audit report..."
    # Capture exit codes cleanly. Lynis returns non-zero warning-based codes.
    # 0 = clean, 1-63 = completed with warnings/suggestions, >= 64 = actual script errors.
    if lynis audit system --quick; then
        log_success "Lynis audit completed."
    else
        local lynis_ec=$?
        if [ "$lynis_ec" -ge 64 ]; then
            log_warning "Lynis audit execution failed to run completely (Exit Code: $lynis_ec)."
        else
            log_success "Lynis system audit complete. Findings and suggestions logged."
        fi
    fi
    
    log_info "View Lynis log metrics under: /var/log/lynis.log"
    if [ -f /var/log/lynis-report.dat ]; then
        local lynis_score
        local lynis_warnings
        local lynis_suggestions

        lynis_warnings=$(awk 'BEGIN {count=0} /^warning\[\]=/ {count++} END {print count}' /var/log/lynis-report.dat)
        lynis_suggestions=$(awk 'BEGIN {count=0} /^suggestion\[\]=/ {count++} END {print count}' /var/log/lynis-report.dat)
        log_info "Lynis reported ${lynis_warnings} warning(s) and ${lynis_suggestions} suggestion(s)."

        lynis_score=$(awk -F= '/^hardening_index=/ {print $2; exit}' /var/log/lynis-report.dat)
        if [[ "$lynis_score" =~ ^[0-9]+$ ]]; then
            if [ "$lynis_score" -ge "$LYNIS_TARGET_SCORE" ]; then
                log_success "Lynis hardening index target met: ${lynis_score}/100 (target ${LYNIS_TARGET_SCORE}+)."
            else
                log_warning "Lynis hardening index is ${lynis_score}/100; target is ${LYNIS_TARGET_SCORE}+."
                log_warning "Review /var/log/lynis.log and /var/log/lynis-report.dat for remaining suggestions."
            fi
        else
            log_warning "Could not parse Lynis hardening index from /var/log/lynis-report.dat."
        fi
    else
        log_warning "Lynis report file not found at /var/log/lynis-report.dat."
    fi

    if [ -f /var/run/reboot-required ]; then
        local reboot_ts_ip
        reboot_ts_ip=$(tailscale ip -4 2>/dev/null | tr -d '[:space:]' || true)
        if [ -n "$reboot_ts_ip" ]; then
            log_warning "A reboot is required to finish applying kernel/service updates. Reconnect after reboot with: ssh -i ~/.ssh/$TARGET_USER-$HOSTNAME_VAL.pem -o IdentitiesOnly=yes -p $TARGET_PORT $TARGET_USER@$reboot_ts_ip"
        else
            log_warning "A reboot is required to finish applying kernel/service updates."
        fi
    fi
}

# Main Execution Orchestrator
main() {
    verify_environment
    configure_base_system
    configure_swap
    install_tailscale
    configure_ssh_hardening
    lock_down_root
    configure_crowdsec
    configure_kernel_hardening
    configure_security_packages
    configure_caddy
    configure_docker
    install_github_deploy_key_helper
    create_health_check
    verify_automatic_updates
    run_lynis_audit
    
    local ts_ip
    ts_ip=$(tailscale ip -4 | tr -d '[:space:]')
    
    printf "\n${GREEN}======================================================================${NC}\n"
    printf "${GREEN}                 PHASE 2 HARDENING SUCCESSFUL                         ${NC}\n"
    printf "${GREEN}======================================================================${NC}\n"
    log_success "All security policies, firewalls, and application nodes are active!"
    log_info "Operating system: $OS_PRETTY"
    log_info "Summary of active endpoints:"
    printf " - SSH Administrative Access:  ${CYAN}ssh -i ~/.ssh/$TARGET_USER-$HOSTNAME_VAL.pem -o IdentitiesOnly=yes -p $TARGET_PORT $TARGET_USER@$ts_ip${NC}\n"
    printf " - HTTP Public Interface:      ${CYAN}Port 80 (Open)${NC}\n"
    printf " - HTTPS Public Interface:     ${CYAN}Port 443 TCP + UDP/HTTP3 (Open)${NC}\n"
    printf " - Web server (Caddy) sites:   ${CYAN}/etc/caddy/sites/*.caddy${NC}\n"
    printf " - Automatic updates:          ${CYAN}nightly 03:30, reboots manual (~/check-health.sh)${NC}\n"
    printf " - Tailscale SSH policy:       ${CYAN}set \"users\": [\"autogroup:nonroot\"] in the tailnet policy${NC}\n"
    printf " - GitHub deploy key per repo: ${CYAN}~/github-deploy-key.sh OWNER/REPO${NC}\n"
    printf "${GREEN}======================================================================${NC}\n\n"
}

main
