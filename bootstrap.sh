#!/usr/bin/env bash

# ==============================================================================
# DEBIAN 13 HARDENED SETUP - PHASE 1: BOOTSTRAP (RUN AS ROOT)
# This script provisions the administrative user and prepares the
# environment for the secondary setup stage.
# ==============================================================================

set -euo pipefail

# Hardened servers use umask 027 for login shells; files this script writes
# (setup.sh copy, cloud-init config, .bashrc) must stay readable.
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

TARGET_USER=""
HOSTNAME_VAL=""
TIMEZONE_VAL=""
DEFAULT_TIMEZONE="Asia/Kolkata"
SSH_PORT="22"
SSH_ACCESS_IP=""
RECONFIGURE_USER="yes"
PASS1=""
SSH_KEY=""
PEM_FILE=""
PEM_OWNER="root"
SERVER_PUBLIC_IP="YOUR_SERVER_PUBLIC_IP"
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

validate_linux_username() {
    local username="$1"
    [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && [ "$username" != "root" ]
}

detect_public_ip() {
    local detected_ip=""

    # Provider-neutral lookups; on NAT'd clouds the local route only shows the private IP.
    detected_ip=$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
    if [ -z "$detected_ip" ]; then
        detected_ip=$(curl -4fsS --max-time 5 https://ifconfig.me/ip 2>/dev/null || true)
    fi
    if [ -z "$detected_ip" ] && command -v ip &>/dev/null; then
        detected_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}')
    fi

    if [[ "$detected_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        SERVER_PUBLIC_IP="$detected_ip"
    else
        log_warning "Could not auto-detect public IPv4 address; final SSH command will use placeholder."
    fi
}

format_ssh_host() {
    local host="$1"

    if [[ "$host" == *:* ]]; then
        printf '[%s]' "$host"
    else
        printf '%s' "$host"
    fi
}

prompt_hostname() {
    local hostname_input
    local current_hostname

    current_hostname="$(hostname -s)"
    while true; do
        read -r -p "Enter server hostname (press Enter to keep '$current_hostname'): " hostname_input
        HOSTNAME_VAL="${hostname_input:-$current_hostname}"
        if [[ "$HOSTNAME_VAL" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
            break
        fi
        log_error "Invalid hostname '$HOSTNAME_VAL'. Use 1-63 letters, numbers, or hyphens; do not start or end with a hyphen."
    done
}

prompt_timezone() {
    local timezone_input
    local current_timezone
    local valid_timezones

    current_timezone="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
    current_timezone="${current_timezone:-UTC}"
    valid_timezones="$(timedatectl list-timezones 2>/dev/null || true)"
    while true; do
        read -r -p "Enter timezone [$DEFAULT_TIMEZONE] (current: $current_timezone): " timezone_input
        TIMEZONE_VAL="${timezone_input:-$DEFAULT_TIMEZONE}"
        if [ -z "$valid_timezones" ] || grep -qxF "$TIMEZONE_VAL" <<< "$valid_timezones"; then
            break
        fi
        log_error "Unknown timezone '$TIMEZONE_VAL'. List valid names with: timedatectl list-timezones"
    done
}

apply_timezone() {
    log_info "Setting timezone to $TIMEZONE_VAL..."
    timedatectl set-timezone "$TIMEZONE_VAL"
    log_success "Timezone set to $TIMEZONE_VAL."
}

apply_hostname() {
    log_info "Setting hostname to $HOSTNAME_VAL..."
    hostnamectl set-hostname "$HOSTNAME_VAL"
    if grep -qE '^127\.0\.1\.1[[:space:]]+' /etc/hosts; then
        sed -i "s|^127\.0\.1\.1.*|127.0.1.1 $HOSTNAME_VAL|" /etc/hosts
    else
        printf '127.0.1.1 %s\n' "$HOSTNAME_VAL" >> /etc/hosts
    fi

    # Most cloud images run cloud-init, which can reset the hostname and
    # regenerate /etc/hosts from provider metadata on every boot.
    if [ -d /etc/cloud/cloud.cfg.d ]; then
        cat << 'EOF' > /etc/cloud/cloud.cfg.d/99-preserve-hostname.cfg
# Written by bootstrap.sh: keep the hostname chosen during server setup.
preserve_hostname: true
manage_etc_hosts: false
EOF
    fi
    log_success "Hostname set to $HOSTNAME_VAL."
}

# After Phase 2, SSH is on a different port and only reachable over Tailscale,
# so a rerun must print that route or the commands will not connect.
detect_ssh_access() {
    local configured_port
    local ts_ip

    configured_port="$(sshd -T 2>/dev/null | awk '$1 == "port" && !found {print $2; found = 1}' || true)"
    if [[ "$configured_port" =~ ^[0-9]+$ ]]; then
        SSH_PORT="$configured_port"
    fi

    if [ "$SSH_PORT" != "22" ] && command -v tailscale &>/dev/null; then
        ts_ip="$(tailscale ip -4 2>/dev/null | tr -d '[:space:]' || true)"
        if [[ "$ts_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            SSH_ACCESS_IP="$ts_ip"
        fi
    fi
}

# On a server already hardened by setup.sh, sshd only admits the users listed
# in AllowUsers. A new admin created here would be refused until added.
ensure_user_allowed_by_sshd() {
    local allowed_users
    local answer
    local backup="/etc/ssh/sshd_config.bootstrap.bak"

    allowed_users="$(sshd -T 2>/dev/null | awk '$1 == "allowusers" {print $2}' || true)"
    if [ -z "$allowed_users" ] || grep -qxF "$TARGET_USER" <<< "$allowed_users"; then
        return 0
    fi

    log_warning "SSH on this server only allows: $(tr '\n' ' ' <<< "$allowed_users")"
    read -r -p "Allow '$TARGET_USER' to log in over SSH as well? (Y/n): " answer
    if [[ "$answer" =~ ^[Nn]$ ]]; then
        log_warning "'$TARGET_USER' was not added to AllowUsers and cannot log in over SSH."
        return 0
    fi

    if ! grep -qE '^AllowUsers[[:space:]]' /etc/ssh/sshd_config; then
        log_warning "AllowUsers is set in an sshd_config.d drop-in; add '$TARGET_USER' there manually."
        return 0
    fi

    cp -p /etc/ssh/sshd_config "$backup"
    sed -i "s/^AllowUsers[[:space:]].*/& $TARGET_USER/" /etc/ssh/sshd_config
    if sshd -t && systemctl reload ssh; then
        log_success "'$TARGET_USER' added to AllowUsers."
    else
        cp -p "$backup" /etc/ssh/sshd_config
        systemctl reload ssh || true
        log_error "Could not update AllowUsers; restored the previous sshd_config."
    fi
}

prompt_admin_username() {
    local username_input
    while true; do
        read -r -p "Enter administrative username: " username_input
        TARGET_USER="$username_input"
        if ! validate_linux_username "$TARGET_USER"; then
            log_error "Invalid username. Use lowercase letters, numbers, underscore, or hyphen; start with a letter/underscore; do not use root."
            continue
        fi
        if id "$TARGET_USER" &>/dev/null && [ "$(id -u "$TARGET_USER")" -lt 1000 ]; then
            log_error "'$TARGET_USER' is an existing system account (UID below 1000). Choose a different username."
            continue
        fi
        break
    done
}

# SSH login always uses an Ed25519 .pem key generated on this server; pasting
# an existing public key or choosing another key type is intentionally not
# offered. Checked during the prompts so nothing changes if it cannot work.
require_ssh_keygen() {
    if ! command -v ssh-keygen &>/dev/null; then
        log_error "ssh-keygen is not installed, so the .pem login key cannot be generated. Install it with: apt-get install -y openssh-client"
        exit 1
    fi
    log_info "SSH login for '$TARGET_USER' will use an Ed25519 .pem key generated on this server (key-only, no password logins)."
}

# Generates the login key pair and stores the private key in the home of the
# account running this script, so it can be downloaded with scp over the
# session that is already working.
generate_pem_key() {
    local owner_home
    local short_host
    local owner_group

    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] && id "$SUDO_USER" &>/dev/null; then
        PEM_OWNER="$SUDO_USER"
    fi
    owner_home="$(getent passwd "$PEM_OWNER" | cut -d: -f6)"
    owner_group="$(id -gn "$PEM_OWNER")"
    short_host="$(hostname -s)"
    PEM_FILE="${owner_home:-/root}/${TARGET_USER}-${short_host}.pem"

    if [ -e "$PEM_FILE" ]; then
        log_warning "Replacing existing key file $PEM_FILE; the old key will no longer be authorized."
        rm -f "$PEM_FILE" "$PEM_FILE.pub"
    fi

    log_info "Generating Ed25519 login key at $PEM_FILE..."
    ssh-keygen -q -t ed25519 -N "" -C "$TARGET_USER@$short_host" -f "$PEM_FILE"

    SSH_KEY="$(cat "$PEM_FILE.pub")"
    rm -f "$PEM_FILE.pub"
    chown "$PEM_OWNER:$owner_group" "$PEM_FILE"
    chmod 600 "$PEM_FILE"
    log_success "Login key generated. Download it before closing this session."
}

finish_pem_key_handoff() {
    local pem_action

    if [ -z "$PEM_FILE" ] || [ ! -f "$PEM_FILE" ]; then
        return 0
    fi

    log_warning "The private key is still stored on this server at $PEM_FILE."
    while true; do
        read -r -p "After downloading it and confirming login works, type 'delete' to remove the server copy, 'show' to print it here, or 'keep': " pem_action
        case "$pem_action" in
            delete)
                shred -u "$PEM_FILE" 2>/dev/null || rm -f "$PEM_FILE"
                log_success "Server copy of the private key removed."
                break
                ;;
            show)
                printf "\n"
                cat "$PEM_FILE"
                printf "\n"
                log_warning "Save everything including the BEGIN/END lines to ~/.ssh/$(basename "$PEM_FILE") on your computer, then run chmod 600 on it."
                ;;
            keep)
                log_warning "Private key left at $PEM_FILE. Remove it once downloaded: shred -u $PEM_FILE"
                break
                ;;
            *)
                log_warning "Please type delete, show, or keep."
                ;;
        esac
    done
}

# 1. Pre-Execution Safety Checks
if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root. Log in as root or run: sudo ./bootstrap.sh"
    exit 1
fi

log_info "Verifying Operating System..."
detect_os

# 2. Interactive Input Gather
prompt_hostname
prompt_timezone
prompt_admin_username
printf "\n=== Provisioning administrative user '%s' ===\n" "$TARGET_USER"

# Check if user already exists
if id "$TARGET_USER" &>/dev/null; then
    log_warning "User '$TARGET_USER' already exists."
    read -r -p "Re-configure user '$TARGET_USER' password and SSH key? (y/N): " recon_user
    if [[ ! "$recon_user" =~ ^[Yy]$ ]]; then
        log_info "Skipping password and SSH key reconfiguration; setup.sh will still be refreshed."
        RECONFIGURE_USER="no"
    elif [ "${SUDO_USER:-}" = "$TARGET_USER" ]; then
        log_warning "You are replacing the SSH key of the account you are logged in as. Keep this session open until the new key works."
    fi
fi

# Ask for password securely
if [ "$RECONFIGURE_USER" = "yes" ]; then
    while true; do
        read -r -s -p "Enter secure password for administrative user '$TARGET_USER': " PASS1
        echo
        read -r -s -p "Confirm password: " PASS2
        echo
        if [ "$PASS1" = "$PASS2" ]; then
            # Matches the pam_pwquality minlen that setup.sh enforces later.
            if [ ${#PASS1} -lt 14 ]; then
                log_warning "Password must be at least 14 characters long. Let's try again."
                continue
            fi
            break
        else
            log_error "Passwords do not match. Let's try again."
        fi
    done

    require_ssh_keygen
fi

# 3. Set Hostname and Timezone, Create User & Configure Environment
apply_hostname
apply_timezone

log_info "Creating user '$TARGET_USER'..."
if ! id "$TARGET_USER" &>/dev/null; then
    adduser --disabled-password --gecos "$TARGET_USER" "$TARGET_USER"
fi

USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
if [ -z "$USER_HOME" ] || [ ! -d "$USER_HOME" ]; then
    log_error "Could not determine home directory for '$TARGET_USER'."
    exit 1
fi

if [ "$RECONFIGURE_USER" = "yes" ]; then
    log_info "Setting user password..."
    printf '%s:%s\n' "$TARGET_USER" "$PASS1" | chpasswd
fi

log_info "Adding '$TARGET_USER' to sudo group..."
apt-get update && apt-get install -y sudo
usermod -aG sudo "$TARGET_USER"

# Double verify groups
if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx sudo; then
    log_success "User '$TARGET_USER' successfully added to sudo group."
else
    log_error "Failed to add user '$TARGET_USER' to sudo group!"
    exit 1
fi

# 4. Set Up SSH Key Directory
if [ "$RECONFIGURE_USER" = "yes" ]; then
    generate_pem_key

    log_info "Setting up SSH authorized keys..."
    mkdir -p "$USER_HOME/.ssh"
    chmod 700 "$USER_HOME/.ssh"
    if [ -s "$USER_HOME/.ssh/authorized_keys" ]; then
        AUTH_KEYS_BACKUP="$USER_HOME/.ssh/authorized_keys.bak.$(date +%Y%m%d%H%M%S)"
        cp -p "$USER_HOME/.ssh/authorized_keys" "$AUTH_KEYS_BACKUP"
        log_info "Previous authorized_keys saved to $AUTH_KEYS_BACKUP."
    fi

    printf '%s\n' "$SSH_KEY" > "$USER_HOME/.ssh/authorized_keys"
    chmod 600 "$USER_HOME/.ssh/authorized_keys"
    chown -R "$TARGET_USER:$TARGET_USER" "$USER_HOME/.ssh"
    log_success "SSH public key configured successfully."
fi

# 5. Fix PATH in .bashrc for the administrative user
log_info "Injecting secure system paths to $TARGET_USER's .bashrc..."
BASHRC="$USER_HOME/.bashrc"
touch "$BASHRC"
chown "$TARGET_USER:$TARGET_USER" "$BASHRC"
if ! grep -q "/sbin" "$BASHRC"; then
    echo 'export PATH="/usr/local/sbin:/usr/sbin:/sbin:$PATH"' >> "$BASHRC"
fi
if ! grep -q 'LC_ALL=en_US.UTF-8' "$BASHRC"; then
    cat << 'EOF' >> "$BASHRC"

# UTF-8 locale for terminal applications such as btop
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
EOF
fi
chown "$TARGET_USER:$TARGET_USER" "$BASHRC"

# Install minimal baseline requirements
log_info "Installing system essentials..."
apt-get install -y curl git nano rsyslog gnupg ca-certificates

log_info "Detecting server public IP for final SSH instructions..."
detect_public_ip
detect_ssh_access
ensure_user_allowed_by_sshd

# Copy setup.sh to the administrative user's home directory so they can execute it
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
SETUP_SRC=""
for path in "$SCRIPT_DIR/setup.sh" "./setup.sh" "/root/setup.sh"; do
    if [ -f "$path" ]; then
        SETUP_SRC="$path"
        break
    fi
done

if [ -n "$SETUP_SRC" ]; then
    log_info "Moving Phase 2 setup script ($SETUP_SRC) to $USER_HOME/ and setting permissions..."
    cp "$SETUP_SRC" "$USER_HOME/setup.sh"
    chown "$TARGET_USER:$TARGET_USER" "$USER_HOME/setup.sh"
    chmod +x "$USER_HOME/setup.sh"
else
    log_warning "Could not automatically locate setup.sh in the current folder, script directory, or /root/."
    log_warning "Please manually copy setup.sh to $USER_HOME/ and run 'chown $TARGET_USER:$TARGET_USER $USER_HOME/setup.sh && chmod +x $USER_HOME/setup.sh' before Phase 2."
fi

# 6. Inform next steps
SSH_HOST="$(format_ssh_host "${SSH_ACCESS_IP:-$SERVER_PUBLIC_IP}")"
SSH_IDENTITY=""
SSH_PORT_OPT=""
SCP_PORT_OPT=""
if [ "$SSH_PORT" != "22" ]; then
    SSH_PORT_OPT="-p $SSH_PORT "
    SCP_PORT_OPT="-P $SSH_PORT "
fi
STEP=1

printf "\n${GREEN}======================================================================${NC}\n"
printf "${GREEN}                     PHASE 1 COMPLETE                                 ${NC}\n"
printf "${GREEN}======================================================================${NC}\n"
log_success "Hostname '$HOSTNAME_VAL', timezone '$TIMEZONE_VAL'; user '$TARGET_USER' is ready with full sudo privileges."
log_info "To ensure you are not locked out, keep this terminal session open!"
log_warning "ACTION REQUIRED:"
printf "%s. Open a ${CYAN}NEW terminal window${NC} on your local computer.\n" "$STEP"
if [ -n "$SSH_ACCESS_IP" ]; then
    printf "   This server is already hardened: SSH works only over Tailscale on port %s, so connect Tailscale first.\n" "$SSH_PORT"
fi
STEP=$((STEP + 1))

if [ -n "$PEM_FILE" ] && [ -f "$PEM_FILE" ]; then
    PEM_NAME="$(basename "$PEM_FILE")"
    SSH_IDENTITY="-i ~/.ssh/$PEM_NAME -o IdentitiesOnly=yes "
    if [ "$PEM_OWNER" = "$TARGET_USER" ] || { [ "$PEM_OWNER" = "root" ] && [ -n "$SSH_ACCESS_IP" ]; }; then
        # scp would need the new key (own account) or a root SSH login, which a
        # hardened server refuses.
        printf "%s. Copy the private key: type 'show' at the prompt below and save the output to ~/.ssh/%s on your computer.\n" "$STEP" "$PEM_NAME"
    else
        printf "%s. Download the private key (run this on your computer, not on the server):\n" "$STEP"
        printf "   ${BLUE}scp %s%s@%s:%s ~/.ssh/%s${NC}\n" "$SCP_PORT_OPT" "$PEM_OWNER" "$SSH_HOST" "$PEM_FILE" "$PEM_NAME"
    fi
    printf "   ${BLUE}chmod 600 ~/.ssh/%s${NC}\n" "$PEM_NAME"
    printf "   Optional, add a passphrase locally: ${BLUE}ssh-keygen -p -f ~/.ssh/%s${NC}\n" "$PEM_NAME"
    STEP=$((STEP + 1))
fi

printf "%s. Log in using your new user account:\n" "$STEP"
printf "   ${BLUE}ssh %s%s%s@%s${NC}\n" "$SSH_IDENTITY" "$SSH_PORT_OPT" "$TARGET_USER" "$SSH_HOST"
STEP=$((STEP + 1))
printf "%s. Once logged in as '%s', verify sudo permissions by running:\n" "$STEP" "$TARGET_USER"
printf "   ${BLUE}sudo whoami${NC} (should output 'root')\n"
STEP=$((STEP + 1))
printf "%s. Run the Phase 2 setup script from your home directory:\n" "$STEP"
printf "   ${BLUE}cd ~ && sudo ./setup.sh${NC}\n"
printf "${GREEN}======================================================================${NC}\n\n"

finish_pem_key_handoff
