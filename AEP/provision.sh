#!/bin/bash
set -e

# Resolve repo root robustly (works whether provision.sh is in repo root or inside AEP/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# If the repo has an AEP/ subdir and this script is above it, use it
if [[ -d "${SCRIPT_DIR}/AEP/scripts" ]]; then
  REPO_PATH="${SCRIPT_DIR}/AEP"
else
  REPO_PATH="${SCRIPT_DIR}"
fi

echo "==> Using REPO_PATH=${REPO_PATH}"

USERNAME="gabe"
SSH_PORT="2222"

echo "======================================================="
echo "   Alter Ego Provisioning (AEP) - Server Bootstrap"
echo "======================================================="


echo "==> Updating system"
apt update -y && apt upgrade -y



# ---------------------------------------------------------
# REMOVE SNAP + BLOCK FUTURE AUTO-INSTALLS
# ---------------------------------------------------------
echo "==> Removing snapd and preventing snap auto-installs"

# Stop snap services if present
systemctl stop snapd 2>/dev/null || true
systemctl disable snapd 2>/dev/null || true
systemctl stop snapd.socket 2>/dev/null || true
systemctl disable snapd.socket 2>/dev/null || true

# Remove snap packages
apt purge -y snapd 2>/dev/null || true

# Remove lxd-installer (this silently installs snapd)
apt purge -y lxd-installer 2>/dev/null || true

# Clean leftover snap directories
rm -rf /snap /var/snap /var/lib/snapd /var/cache/snapd 2>/dev/null || true

echo "==> Snap removed and blocked successfully"



# ---------------------------------------------------------
# INSTALL PIPX + LINODE CLI
# ---------------------------------------------------------
echo "==> Installing pipx + Linode CLI"

apt install -y pipx
pipx ensurepath

# Add pipx bin path for root
if ! grep -q "/root/.local/bin" /root/.bashrc; then
    echo 'export PATH="/root/.local/bin:$PATH"' >> /root/.bashrc
fi

export PATH="/root/.local/bin:$PATH"

pipx install --force linode-cli

echo "==> Verifying Linode CLI installation"
which linode-cli || echo "ERROR: linode-cli not found in PATH"
linode-cli --version || echo "ERROR: linode-cli failed to execute"

echo "==> Linode CLI installed successfully"

# ---------------------------------------------------------
# CREATE USER & SSH SETUP
# ---------------------------------------------------------
echo "==> Creating privileged user: $USERNAME"

if ! id "$USERNAME" &>/dev/null; then
    adduser --disabled-password --gecos "" "$USERNAME"
fi

echo "==> Enabling passwordless sudo"
usermod -aG sudo "$USERNAME"
echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-$USERNAME
chmod 440 /etc/sudoers.d/90-$USERNAME


echo "==> Preparing SSH directory and keys for user"
mkdir -p /home/$USERNAME/.ssh
chmod 700 /home/$USERNAME/.ssh

if [ ! -f "/home/$USERNAME/.ssh/id_ed25519" ]; then
    echo "==> Generating SSH keypair"
    ssh-keygen -t ed25519 -f /home/$USERNAME/.ssh/id_ed25519 -N "" -C "$USERNAME@$(hostname)"
fi

cat /home/$USERNAME/.ssh/id_ed25519.pub > /home/$USERNAME/.ssh/authorized_keys
chmod 600 /home/$USERNAME/.ssh/authorized_keys
chown -R $USERNAME:$USERNAME /home/$USERNAME/.ssh



# ---------------------------------------------------------
# SSH HARDENING
# ---------------------------------------------------------
echo "==> Hardening SSH"

mkdir -p /run/sshd
chmod 755 /run/sshd

sed -i '/^[Pp]ort /d' /etc/ssh/sshd_config
echo "Port $SSH_PORT" >> /etc/ssh/sshd_config

sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config || true
sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config || true

sed -i 's/#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config || true
sed -i 's/PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config || true

sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config || true

echo "==> Validating SSH config"
sshd -t

systemctl restart ssh
echo "==> SSH hardened and restarted"



# ---------------------------------------------------------
# FIREWALL SETUP
# ---------------------------------------------------------
echo "==> Configuring UFW firewall"

ufw default deny incoming
ufw default allow outgoing
ufw allow "$SSH_PORT"/tcp
ufw --force enable



# ---------------------------------------------------------
# INSTALL MSMTP CONFIG
# ---------------------------------------------------------
echo "==> Installing msmtp config"

install -m 600 "$REPO_PATH/config/msmtprc" /etc/msmtprc
touch /var/log/msmtp.log
chmod 640 /var/log/msmtp.log || true

# ---------------------------------------------------------
# INSTALL OPS MONITOR (alerts + weekly summary)
# ---------------------------------------------------------
echo "==> Installing ops-monitor (threshold alerts + weekly summary)"

# Ensure dirs exist
mkdir -p /etc/ops-monitor/roles
mkdir -p /var/lib/ops-monitor
mkdir -p /usr/local/sbin

# Install ops-monitor scripts
install -m 0644 "$REPO_PATH/scripts/ops-monitor/bin/ops-monitor-lib.sh" /usr/local/sbin/ops-monitor-lib.sh
install -m 0755 "$REPO_PATH/scripts/ops-monitor/bin/ops-threshold-check.sh" /usr/local/sbin/ops-threshold-check
install -m 0755 "$REPO_PATH/scripts/ops-monitor/bin/ops-weekly-summary.sh"  /usr/local/sbin/ops-weekly-summary

# Install legacy health check as a uniform command (still included in weekly summary)
install -m 0755 "$REPO_PATH/scripts/server_health_check.sh" /usr/local/sbin/server_health_check

# Install ops-monitor config (only if missing; do not clobber real settings)
if [[ ! -f /etc/ops-monitor/ops.conf ]]; then
  install -m 0644 "$REPO_PATH/config/ops-monitor/ops.conf" /etc/ops-monitor/ops.conf
  echo "   -> Created /etc/ops-monitor/ops.conf (edit OPS_TO/OPS_FROM)"
else
  echo "   -> Keeping existing /etc/ops-monitor/ops.conf"
fi

# Install role overlays (safe to overwrite from repo templates)
install -m 0644 "$REPO_PATH/config/ops-monitor/roles/"*.conf /etc/ops-monitor/roles/ 2>/dev/null || true

# Set role (you should define SERVER_ROLE earlier; default base)
SERVER_ROLE="${SERVER_ROLE:-base}"
echo "$SERVER_ROLE" > /etc/ops-monitor/role
chmod 0644 /etc/ops-monitor/role

# Install systemd units
install -m 0644 "$REPO_PATH/scripts/ops-monitor/systemd/ops-threshold-check.service" /etc/systemd/system/ops-threshold-check.service
install -m 0644 "$REPO_PATH/scripts/ops-monitor/systemd/ops-threshold-check.timer"   /etc/systemd/system/ops-threshold-check.timer
install -m 0644 "$REPO_PATH/scripts/ops-monitor/systemd/ops-weekly-summary.service" /etc/systemd/system/ops-weekly-summary.service
install -m 0644 "$REPO_PATH/scripts/ops-monitor/systemd/ops-weekly-summary.timer"   /etc/systemd/system/ops-weekly-summary.timer

# Enable timers
systemctl daemon-reload
systemctl enable --now ops-threshold-check.timer ops-weekly-summary.timer

echo "==> ops-monitor installed (role=${SERVER_ROLE})"



# ---------------------------------------------------------
# CRON JOBS
# ---------------------------------------------------------
echo "==> Installing cron jobs for monitoring"

cat > /etc/cron.d/server_health_check << 'EOF'
*/5 * * * * root /usr/local/bin/server_health_check.sh
0 9 * * SUN root /usr/local/bin/server_health_check.sh summary
EOF

chmod 644 /etc/cron.d/server_health_check



# ---------------------------------------------------------
# OUTPUT PRIVATE SSH KEY
# ---------------------------------------------------------
echo "======================================================="
echo "              SSH PRIVATE KEY FOR $USERNAME"
echo "======================================================="
echo
cat /home/$USERNAME/.ssh/id_ed25519
echo
echo "SAVE THIS KEY NOW — YOU WILL NOT SEE IT AGAIN"
echo "======================================================="


echo "==> Provisioning complete!"
echo "User: $USERNAME"
echo "SSH Port: $SSH_PORT"
echo "Monitoring: server_health_check.sh + cron"
echo "Linode CLI: pipx-installed"
echo "Snap: REMOVED & BLOCKED"
echo "======================================================="
