#!/usr/bin/env bash

# ==============================================================================
# DEBIAN 13 HARDENED SETUP - PHASE 2: SYSTEM HARDENING (RUN AS SUDO)
# Optimized for Debian 13 (Trixie), Kernel 6.12, and a configurable admin user
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

# Global Variables
DEFAULT_TARGET_USER="${TARGET_USER:-${SUDO_USER:-ananthu}}"
if [ "$DEFAULT_TARGET_USER" = "root" ]; then
    DEFAULT_TARGET_USER="ananthu"
fi
TARGET_USER="$DEFAULT_TARGET_USER"
TARGET_HOME=""
TARGET_PORT="2626"
TIMEZONE="Asia/Kolkata"
HOSTNAME_VAL="core"
LYNIS_TARGET_SCORE=83
SSH_ROLLBACK_UNIT="ssh-hardening-rollback"
SSH_ROLLBACK_SCRIPT="/root/ssh-hardening-rollback.sh"
SSH_ROLLBACK_DELAY_MINUTES=10

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

    if [ -f /etc/ssh/sshd_config.bak ]; then
        cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
        echo "Restored /etc/ssh/sshd_config from backup."
    else
        echo "No /etc/ssh/sshd_config.bak found; keeping current sshd_config."
    fi

    if command -v sshd >/dev/null 2>&1; then
        sshd -t || echo "Warning: restored sshd_config did not validate cleanly."
    fi

    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true

    if command -v ufw >/dev/null 2>&1; then
        ufw --force disable || true
        echo "UFW disabled for emergency access."
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
    if [ -f /etc/ssh/sshd_config.bak ]; then
        cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
    fi
    sshd -t || true
    systemctl restart ssh || systemctl restart sshd || true
    if command -v ufw >/dev/null 2>&1; then
        log_info "Disabling UFW to ensure you are not locked out..."
        ufw --force disable || true
    fi
    cancel_ssh_rollback_timer
    log_info "SSH rollback completed. Previous SSH config restored where possible, and UFW is disabled."
}

validate_linux_username() {
    local username="$1"
    [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && [ "$username" != "root" ]
}

prompt_target_user() {
    local username_input

    while true; do
        read -r -p "Enter administrative username [$DEFAULT_TARGET_USER]: " username_input
        TARGET_USER="${username_input:-$DEFAULT_TARGET_USER}"
        if validate_linux_username "$TARGET_USER"; then
            break
        fi
        log_error "Invalid username. Use lowercase letters, numbers, underscore, or hyphen; start with a letter/underscore; do not use root."
    done

    if ! id "$TARGET_USER" &>/dev/null; then
        log_error "User '$TARGET_USER' does not exist. Run bootstrap.sh first or choose an existing sudo user."
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

# 1. Pre-Execution Checks
verify_environment() {
    log_info "Verifying execution context..."
    
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run with sudo! Run: sudo ./setup.sh"
        exit 1
    fi

    prompt_target_user
    
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
    
    log_info "Configuring timezone to $TIMEZONE..."
    timedatectl set-timezone "$TIMEZONE"
    timedatectl status | grep "Time zone"

    log_info "Configuring UTF-8 locale for terminal applications..."
    apt update
    apt install -y locales
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
    
    read -r -p "Enter server hostname [$HOSTNAME_VAL]: " HOSTNAME_INPUT
    HOSTNAME_VAL="${HOSTNAME_INPUT:-$HOSTNAME_VAL}"
    if [[ ! "$HOSTNAME_VAL" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
        log_error "Invalid hostname '$HOSTNAME_VAL'. Use 1-63 letters, numbers, or hyphens; do not start or end with a hyphen."
        exit 1
    fi

    log_info "Configuring hostname to $HOSTNAME_VAL..."
    hostnamectl set-hostname "$HOSTNAME_VAL"
    if grep -qE '^127\.0\.1\.1[[:space:]]+' /etc/hosts; then
        sed -i "s|^127\.0\.1\.1.*|127.0.1.1 $HOSTNAME_VAL|" /etc/hosts
    else
        printf '127.0.1.1 %s\n' "$HOSTNAME_VAL" >> /etc/hosts
    fi
    
    log_info "Updating apt packages & installing baseline requirements..."
    apt update && apt upgrade -y && apt autoremove -y

    log_info "Installing essential admin and diagnostics tools..."
    apt install -y \
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
    apt install -y rsyslog
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
    
    if ! tailscale up --ssh --accept-dns=true --accept-routes=true; then
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

    schedule_ssh_rollback_timer
    
    log_info "Writing hardened SSH configuration..."
    cat << EOF > /etc/ssh/sshd_config
# Hardened OpenSSH Daemon Configuration (Debian 13)
#
# Do not bind sshd to the Tailscale IP with ListenAddress.
# On reboot, ssh can start before tailscale0 receives its IP, which makes
# port $TARGET_PORT refuse connections. UFW restricts this port to tailscale0.

Port $TARGET_PORT
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
AllowUsers $TARGET_USER
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
    log_warning "   ssh -p $TARGET_PORT $TARGET_USER@$ts_ip"
    log_warning "======================================================================"
    
    while true; do
        read -r -p "Did the new SSH connection connect successfully? (yes/no): " ssh_success
        if [[ "$ssh_success" =~ ^[Yy][Ee][Ss]$ ]]; then
            cancel_ssh_rollback_timer
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
    apt install -y ufw
    
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
    
    # Open port 2626 specifically on the tailscale0 interface
    ufw allow in on tailscale0 to any port "$TARGET_PORT" proto tcp comment 'SSH via Tailscale only'
    
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
    if grep root /etc/shadow | cut -d: -f2 | grep -qE '^(!|\*)'; then
        log_success "Root account successfully locked."
    else
        log_warning "Verify root lock failed. Shadow record does not start with ! or *."
    fi
}

# 8. CrowdSec IPS Setup
configure_crowdsec() {
    printf "\n=== 6. CrowdSec IPS Setup ===\n"
    
    log_info "Installing CrowdSec official version..."
    curl -fsSL https://install.crowdsec.net | bash

    log_info "Installing CrowdSec engine..."
    apt update
    apt install -y crowdsec
    
    systemctl enable --now crowdsec

    log_info "Installing NFTables firewall bouncer..."
    if ! apt install -y crowdsec-firewall-bouncer-nftables; then
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
    systemctl enable --now crowdsec-firewall-bouncer
    
    log_info "Updating CrowdSec Hub..."
    cscli hub update
    
    log_info "Installing standard CrowdSec log detection collections..."
    install_crowdsec_collection crowdsecurity/linux
    install_crowdsec_collection crowdsecurity/sshd
    install_crowdsec_collection crowdsecurity/nginx
    
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

    log_info "Writing CrowdSec acquisition configuration..."
    cat << 'EOF' > /etc/crowdsec/acquis.yaml
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
EOF


    log_info "Starting CrowdSec services..."
    systemctl restart crowdsec
    systemctl enable crowdsec
    
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

# Disable IP forwarding
net.ipv4.ip_forward = 0
net.ipv6.conf.all.forwarding = 0
net.ipv4.conf.all.forwarding = 0

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

# 10. Security Packages & auditd Rules
configure_security_packages() {
    printf "\n=== 8. Security Packages & Auditing ===\n"
    
    log_info "Installing security monitoring packages..."
    apt install -y \
      libpam-tmpdir \
      libpam-pwquality \
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

    log_info "Configuring unattended security upgrades only..."
    cat << 'EOF' > /etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Enable "1";
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
    cat << 'EOF' > /etc/apt/apt.conf.d/50unattended-upgrades
Unattended-Upgrade::Origins-Pattern {
        "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
};

Unattended-Upgrade::Package-Blacklist {
};

Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::InstallOnShutdown "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::SyslogEnable "true";
Unattended-Upgrade::SyslogFacility "daemon";
EOF
    systemctl enable --now unattended-upgrades || log_warning "unattended-upgrades service could not be started automatically."
    systemctl enable --now cron || log_warning "cron service could not be started automatically."

    log_info "Configuring auditd hardening rules..."
    systemctl enable --now auditd || log_warning "auditd service could not be enabled immediately; continuing after writing rules."
    cat << 'EOF' > /etc/audit/rules.d/hardening.rules
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/sudoers -p wa -k sudoers
-w /etc/ssh/sshd_config -p wa -k sshd_config
-w /etc/crontab -p wa -k cron
-w /var/spool/cron -p wa -k cron
-a always,exit -F arch=b64 -S execve -F euid=0 -k root_commands
EOF
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
    
    log_info "Writing unauthorized access login banners..."
    cat << 'EOF' > /etc/issue
Authorized access only. All activity is monitored and logged.
Unauthorized access is prohibited and will be prosecuted.
EOF
    cp /etc/issue /etc/issue.net
    
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

# 11. Nginx Web Server Setup
configure_nginx() {
    printf "\n=== 9. Nginx Web Server Setup ===\n"

    log_info "Installing Nginx..."
    apt install -y nginx

    log_info "Writing default Nginx site..."
    mkdir -p /var/www/html /etc/nginx/conf.d
    cat << EOF > /var/www/html/index.html
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>$HOSTNAME_VAL</title>
  <style>
    body { font-family: sans-serif; margin: 3rem; line-height: 1.5; color: #111; }
    code { background: #f4f4f4; padding: 0.15rem 0.3rem; }
  </style>
</head>
<body>
  <h1>$HOSTNAME_VAL is online</h1>
  <p>Nginx is installed and serving the default site.</p>
  <p>Health check: <code>/health</code></p>
</body>
</html>
EOF

    # Some Debian images or prior hardening passes already set server_tokens
    # globally. Avoid a duplicate directive in conf.d that can break nginx -t.
    if [ -f /etc/nginx/conf.d/hardening.conf ] && grep -q '^[[:space:]]*server_tokens[[:space:]]\+off;' /etc/nginx/conf.d/hardening.conf; then
        rm -f /etc/nginx/conf.d/hardening.conf
    fi

    cat << 'EOF' > /etc/nginx/sites-available/default
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    server_name _;
    root /var/www/html;
    index index.html;

    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;

    server_tokens off;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;

    location = /health {
        access_log off;
        default_type text/plain;
        return 200 "ok\n";
    }

    location / {
        try_files $uri $uri/ =404;
    }

    location ~ /\.(?!well-known) {
        deny all;
    }
}
EOF

    ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default

    log_info "Validating Nginx configuration..."
    nginx -t
    systemctl enable --now nginx
    systemctl reload nginx

    log_success "Nginx default site is active on HTTP port 80."
}

# 12. Docker Setup
configure_docker() {
    printf "\n=== 10. Docker Configuration ===\n"
    
    if command -v docker &>/dev/null && docker compose version &>/dev/null; then
        log_info "Docker Engine and Compose plugin are already installed."
    else
        log_info "Installing Docker Engine dependencies..."
        apt update && apt install -y ca-certificates curl gnupg
        
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
        apt update
        apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    fi
    
    log_info "Adding '$TARGET_USER' to docker group..."
    usermod -aG docker "$TARGET_USER"
    
    log_info "Writing secure docker daemon configurations..."
    mkdir -p /etc/docker
    cat << 'EOF' > /etc/docker/daemon.json
{
  "iptables": true,
  "ip6tables": true,
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
    systemctl restart docker
    systemctl enable docker

    log_success "Docker Engine configured successfully."
}

# 13. GitHub SSH Keys Creation
configure_github_ssh() {
    printf "\n=== 11. GitHub SSH Deployment Keys ===\n"
    
    local user_home="$TARGET_HOME"
    local ssh_dir="$user_home/.ssh"

    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"
    chown "$TARGET_USER:$TARGET_USER" "$ssh_dir"
    
    if [ -f "$ssh_dir/github" ]; then
        log_info "GitHub SSH key already exists."
        if [ ! -f "$ssh_dir/github.pub" ]; then
            log_info "Regenerating missing GitHub public key file..."
            ssh-keygen -y -f "$ssh_dir/github" > "$ssh_dir/github.pub"
        fi
    else
        log_info "Generating safe Ed25519 deployment key..."
        # Non-interactive deploy key generation for automation-friendly setup.
        ssh-keygen -t ed25519 -C "$TARGET_USER@$HOSTNAME_VAL" -f "$ssh_dir/github" -N ""
        chown -R "$TARGET_USER:$TARGET_USER" "$ssh_dir"
    fi
    
    log_info "Creating custom SSH configuration profile..."
    cat << EOF > "$ssh_dir/config"
Host github.com
    HostName github.com
    User git
    IdentityFile ~/.ssh/github
    IdentitiesOnly yes
EOF
    chmod 600 "$ssh_dir/config"
    chmod 600 "$ssh_dir/github"
    chmod 644 "$ssh_dir/github.pub"
    chown -R "$TARGET_USER:$TARGET_USER" "$ssh_dir"
    
    log_info "Persisting ssh-agent on login inside .bashrc..."
    local bash_profile="$user_home/.bashrc"
    touch "$bash_profile"
    chown "$TARGET_USER:$TARGET_USER" "$bash_profile"
    if ! grep -q "ssh-agent" "$bash_profile"; then
        cat << 'EOF' >> "$bash_profile"

# Start SSH Agent and import GitHub deployments keys
if [ -z "$SSH_AUTH_SOCK" ]; then
  eval "$(ssh-agent -s)" >/dev/null
  ssh-add ~/.ssh/github 2>/dev/null
fi
EOF
        chown "$TARGET_USER:$TARGET_USER" "$bash_profile"
    fi
    
    printf "\n${YELLOW}=== ACTION REQUIRED: ADD THIS KEY TO GITHUB ===${NC}\n"
    cat "$ssh_dir/github.pub"
    printf "${YELLOW}=================================================${NC}\n\n"

    while true; do
        read -r -p "Have you added this public key to GitHub? (yes/no): " github_key_added
        if [[ "$github_key_added" =~ ^[Yy]([Ee][Ss])?$ ]]; then
            log_info "Testing GitHub SSH authentication as '$TARGET_USER'..."
            ssh-keyscan -H github.com >> "$ssh_dir/known_hosts" 2>/dev/null || true
            chmod 644 "$ssh_dir/known_hosts" 2>/dev/null || true
            chown -R "$TARGET_USER:$TARGET_USER" "$ssh_dir"

            set +e
            github_test_output=$(sudo -H -u "$TARGET_USER" ssh -F "$ssh_dir/config" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1)
            github_test_status=$?
            set -e

            printf "%s\n" "$github_test_output"
            if [[ "$github_test_output" == *"successfully authenticated"* ]]; then
                log_success "GitHub SSH authentication works."
            else
                log_warning "GitHub SSH authentication did not confirm successfully (exit code: $github_test_status)."
                log_warning "Verify the key was added to GitHub and try: ssh -T git@github.com"
            fi
            break
        elif [[ "$github_key_added" =~ ^[Nn]([Oo])?$ ]]; then
            log_warning "Skipping GitHub SSH test. Add the key later and test with: ssh -T git@github.com"
            break
        else
            log_warning "Please type 'yes' or 'no'."
        fi
    done
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

echo -e "\n${YELLOW}6. Nginx Service Health:${NC}"
systemctl is-active nginx 2>/dev/null || echo "Nginx is not active."
curl -fsS http://127.0.0.1/health 2>/dev/null || echo "Nginx health endpoint unavailable."

echo -e "\n${YELLOW}7. Reboot Requirement:${NC}"
if [ -f /var/run/reboot-required ]; then
    cat /var/run/reboot-required
else
    echo "No reboot-required marker found."
fi

echo -e "\n${YELLOW}8. Lynis Hardening Index:${NC}"
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
            log_warning "A reboot is required to finish applying kernel/service updates. Reconnect after reboot with: ssh -p $TARGET_PORT $TARGET_USER@$reboot_ts_ip"
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
    configure_nginx
    configure_docker
    configure_github_ssh
    create_health_check
    run_lynis_audit
    
    local ts_ip
    ts_ip=$(tailscale ip -4 | tr -d '[:space:]')
    
    printf "\n${GREEN}======================================================================${NC}\n"
    printf "${GREEN}                 PHASE 2 HARDENING SUCCESSFUL                         ${NC}\n"
    printf "${GREEN}======================================================================${NC}\n"
    log_success "All security policies, firewalls, and application nodes are active!"
    log_info "Summary of active endpoints:"
    printf " - SSH Administrative Access:  ${CYAN}ssh -p $TARGET_PORT $TARGET_USER@$ts_ip${NC}\n"
    printf " - HTTP Public Interface:      ${CYAN}Port 80 (Open)${NC}\n"
    printf " - HTTPS Public Interface:     ${CYAN}Port 443 (Open)${NC}\n"
    printf "${GREEN}======================================================================${NC}\n\n"
}

main
