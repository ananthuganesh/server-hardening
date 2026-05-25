#!/usr/bin/env bash

# ==============================================================================
# DEBIAN 13 HARDENED SETUP - PHASE 1: BOOTSTRAP (RUN AS ROOT)
# This script provisions the administrative user and prepares the
# environment for the secondary setup stage.
# ==============================================================================

set -euo pipefail

export DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"
export NEEDRESTART_MODE="${NEEDRESTART_MODE:-a}"

# Text Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

DEFAULT_TARGET_USER="${TARGET_USER:-ananthu}"
TARGET_USER=""
RECONFIGURE_USER="yes"
PASS1=""
SSH_KEY=""
SERVER_PUBLIC_IP="YOUR_SERVER_PUBLIC_IP"

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

validate_linux_username() {
    local username="$1"
    [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && [ "$username" != "root" ]
}

detect_public_ip() {
    local detected_ip=""

    detected_ip=$(curl -4fsS --max-time 3 http://169.254.169.254/hetzner/v1/metadata/public-ipv4 2>/dev/null || true)
    if [ -z "$detected_ip" ]; then
        detected_ip=$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
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

prompt_admin_username() {
    local username_input
    while true; do
        read -r -p "Enter administrative username [$DEFAULT_TARGET_USER]: " username_input
        TARGET_USER="${username_input:-$DEFAULT_TARGET_USER}"
        if validate_linux_username "$TARGET_USER"; then
            break
        fi
        log_error "Invalid username. Use lowercase letters, numbers, underscore, or hyphen; start with a letter/underscore; do not use root."
    done
}

# 1. Pre-Execution Safety Checks
if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root. Please run: ssh root@YOUR_SERVER_IP"
    exit 1
fi

log_info "Verifying Operating System..."
if [ -f /etc/os-release ]; then
    OS_NAME=$(grep -oP '(?<=^NAME=")[^"]+' /etc/os-release || echo "")
    OS_VERSION=$(grep -oP '(?<=^VERSION_ID=")[^"]+' /etc/os-release || echo "")
    
    if [[ ! "$OS_NAME" =~ "Debian" ]] || [[ "$OS_VERSION" != "13" ]]; then
        log_warning "This script is optimized for Debian 13 (Trixie). Found: $OS_NAME $OS_VERSION"
        read -r -p "Do you want to continue anyway? (y/N): " continue_os
        if [[ ! "$continue_os" =~ ^[Yy]$ ]]; then
            log_error "Execution halted by user."
            exit 1
        fi
    else
        log_success "Verified OS: Debian 13 (Trixie)"
    fi
else
    log_error "Could not determine OS version (/etc/os-release missing)."
    exit 1
fi

# 2. Interactive Input Gather
prompt_admin_username
printf "\n=== Provisioning administrative user '%s' ===\n" "$TARGET_USER"

# Check if user already exists
if id "$TARGET_USER" &>/dev/null; then
    log_warning "User '$TARGET_USER' already exists."
    read -r -p "Re-configure user '$TARGET_USER' password and SSH key? (y/N): " recon_user
    if [[ ! "$recon_user" =~ ^[Yy]$ ]]; then
        log_info "Skipping password and SSH key reconfiguration; setup.sh will still be refreshed."
        RECONFIGURE_USER="no"
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
            if [ ${#PASS1} -lt 12 ]; then
                log_warning "Password should be at least 12 characters long. Let's try again."
                continue
            fi
            break
        else
            log_error "Passwords do not match. Let's try again."
        fi
    done

    # Ask for SSH public key
    printf "\n"
    log_info "An SSH Public Key is required for safe, passwordless access."
    while true; do
        read -r -p "Paste your SSH Public Key (e.g. ssh-ed25519 AAAAC3...): " SSH_KEY
        if [[ "$SSH_KEY" =~ ^ssh- ]]; then
            break
        else
            log_error "Invalid key format. Must start with ssh-rsa, ssh-ed25519, etc. Please try again."
        fi
    done
fi

# 3. Create User & Configure Environment
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
apt update && apt install -y sudo
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
    log_info "Setting up SSH authorized keys..."
    mkdir -p "$USER_HOME/.ssh"
    chmod 700 "$USER_HOME/.ssh"

    echo "$SSH_KEY" > "$USER_HOME/.ssh/authorized_keys"
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
apt install -y curl git nano rsyslog gnupg apt-transport-https ca-certificates

log_info "Detecting server public IP for final SSH instructions..."
detect_public_ip

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
printf "\n${GREEN}======================================================================${NC}\n"
printf "${GREEN}                     PHASE 1 COMPLETE                                 ${NC}\n"
printf "${GREEN}======================================================================${NC}\n"
log_success "User '$TARGET_USER' is ready with full sudo privileges."
log_info "To ensure you are not locked out, keep this terminal session open!"
log_warning "ACTION REQUIRED:"
printf "1. Open a ${CYAN}NEW terminal window${NC} on your local computer.\n"
printf "2. Log in using your new user account:\n"
printf "   ${BLUE}ssh $TARGET_USER@$(format_ssh_host "$SERVER_PUBLIC_IP")${NC}\n"
printf "3. Once logged in as '$TARGET_USER', verify sudo permissions by running:\n"
printf "   ${BLUE}sudo whoami${NC} (should output 'root')\n"
printf "4. Run the Phase 2 setup script from your home directory:\n"
printf "   ${BLUE}cd ~ && sudo ./setup.sh${NC}\n"
printf "${GREEN}======================================================================${NC}\n\n"
