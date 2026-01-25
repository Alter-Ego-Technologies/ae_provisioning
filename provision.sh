#!/bin/bash
set -e

# Resolve repo root robustly (works whether provision.sh is in repo root or inside AEP/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_PATH="${SCRIPT_DIR}"

# Configuration from environment or defaults
ADMIN_USER="${ADMIN_USER:-gabe}"
SSH_PORT="${SSH_PORT:-2222}"
LOG_FILE="${LOG_FILE:-/var/log/provision.log}"

# Colors and emoji helpers (disable with NO_COLOR=1 or when not a TTY)
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  CYAN="\033[1;36m"; GREEN="\033[1;32m"; YELLOW="\033[1;33m"; RED="\033[1;31m"; BOLD="\033[1m"; RESET="\033[0m"
else
  CYAN=""; GREEN=""; YELLOW=""; RED=""; BOLD=""; RESET=""
fi

step()   { printf "%b\n" "${CYAN}➡️  $*${RESET}"; }
ok()     { printf "%b\n" "${GREEN}✅ $*${RESET}"; }
warn()   { printf "%b\n" "${YELLOW}⚠️  $*${RESET}"; }
err()    { printf "%b\n" "${RED}⛔ $*${RESET}"; }
banner() { printf "%b\n" "${BOLD}$*${RESET}"; }
rule()   { printf "%b\n" "${BOLD}=======================================================${RESET}"; }

step "Using REPO_PATH=${REPO_PATH}"
step "Logging to ${LOG_FILE}"

# Redirect output to both console and log file
exec > >(tee -a "${LOG_FILE}")
exec 2>&1

# Validate required config files exist
step "Validating required files"
for required_file in "$REPO_PATH/config/msmtprc" "$REPO_PATH/config/ops-monitor/ops.conf"; do
  if [[ ! -f "$required_file" ]]; then
    err "Required file not found: $required_file"
    exit 1
  fi
done
ok "All required files present"

rule
banner "Alter Ego Provisioning (AEP) - Server Bootstrap"
rule
banner "Admin user: ${ADMIN_USER}"
banner "SSH port: ${SSH_PORT}"
rule

step "Updating system"
apt update -y && apt upgrade -y

# ---------------------------------------------------------
# REMOVE SNAP + BLOCK FUTURE AUTO-INSTALLS
# ---------------------------------------------------------
step "Removing snapd and preventing snap auto-installs"

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

ok "Snap removed and blocked successfully"

# ---------------------------------------------------------
# INSTALL PIPX + LINODE CLI
# ---------------------------------------------------------
step "Installing pipx + Linode CLI"

apt install -y pipx
pipx ensurepath

# Add pipx bin path for root
if ! grep -q "/root/.local/bin" /root/.bashrc; then
    echo 'export PATH="/root/.local/bin:$PATH"' >> /root/.bashrc
fi

export PATH="/root/.local/bin:$PATH"

pipx install --force linode-cli

step "Verifying Linode CLI installation"
which linode-cli || echo "ERROR: linode-cli not found in PATH"
linode-cli --version || echo "ERROR: linode-cli failed to execute"

ok "Linode CLI installed successfully"

# ---------------------------------------------------------
# CREATE USER & SSH SETUP
# ---------------------------------------------------------
if id -u "$ADMIN_USER" >/dev/null 2>&1; then
  ok "User '$ADMIN_USER' already exists, skipping creation"
else
  step "Creating user '$ADMIN_USER'"
  useradd -m -s /bin/bash "$ADMIN_USER"
fi

step "Enabling passwordless sudo"
usermod -aG sudo,adm,systemd-journal,docker "$ADMIN_USER"
echo "$ADMIN_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-$ADMIN_USER
chmod 440 /etc/sudoers.d/90-$ADMIN_USER


step "Preparing SSH directory and keys for user"
mkdir -p /home/$ADMIN_USER/.ssh
chmod 700 /home/$ADMIN_USER/.ssh

if [ ! -f "/home/$ADMIN_USER/.ssh/id_ed25519" ]; then
    step "Generating SSH keypair"
    ssh-keygen -t ed25519 -f /home/$ADMIN_USER/.ssh/id_ed25519 -N "" -C "$ADMIN_USER@$(hostname)"
    ok "Verifying key"
    ssh-keygen -l -f /home/$ADMIN_USER/.ssh/id_ed25519
fi

cat /home/$ADMIN_USER/.ssh/id_ed25519.pub > /home/$ADMIN_USER/.ssh/authorized_keys
chmod 600 /home/$ADMIN_USER/.ssh/authorized_keys
chown -R $ADMIN_USER:$ADMIN_USER /home/$ADMIN_USER/.ssh

# ---------------------------------------------------------
# SSH HARDENING
# ---------------------------------------------------------
step "Hardening SSH"

mkdir -p /run/sshd
chmod 755 /run/sshd

sed -i '/^[Pp]ort /d' /etc/ssh/sshd_config
echo "Port $SSH_PORT" >> /etc/ssh/sshd_config

sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config || true
sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config || true

sed -i 's/#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config || true
sed -i 's/PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config || true

sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config || true

step "Validating SSH config"
sshd -t

systemctl restart ssh
ok "SSH hardened and restarted"

# ---------------------------------------------------------
# FIREWALL SETUP
# ---------------------------------------------------------
step "Configuring UFW firewall"
ufw default deny incoming
ufw default allow outgoing
ufw allow "$SSH_PORT"/tcp
ufw --force enable

# ---------------------------------------------------------
# INSTALL MSMTP (base packages + config)
# ---------------------------------------------------------
step "Installing msmtp packages and config"

apt install -y msmtp msmtp-mta ca-certificates
install -m 600 "$REPO_PATH/config/msmtprc" /etc/msmtprc
chown root:root /etc/msmtprc
touch /var/log/msmtp.log
chown root:adm /var/log/msmtp.log
chmod 640 /var/log/msmtp.log

# ---------------------------------------------------------
# INSTALL OPS MONITOR (alerts + weekly summary)
# ---------------------------------------------------------
step "Installing ops-monitor (threshold alerts + weekly summary)"

# Ensure dirs exist
mkdir -p /etc/ops-monitor/roles
mkdir -p /var/lib/ops-monitor
mkdir -p /usr/local/sbin
mkdir -p /opt/ae_provisioning

chown -R $ADMIN_USER:$ADMIN_USER /opt/ae_provisioning || true

# Install ops-monitor scripts
install -m 0644 "$REPO_PATH/scripts/ops-monitor/bin/ops-monitor-lib.sh" /usr/local/sbin/ops-monitor-lib.sh
install -m 0755 "$REPO_PATH/scripts/ops-monitor/bin/ops-threshold-check.sh" /usr/local/sbin/ops-threshold-check
install -m 0755 "$REPO_PATH/scripts/ops-monitor/bin/ops-weekly-summary.sh"  /usr/local/sbin/ops-weekly-summary

# Install legacy health check as a uniform command (still included in weekly summary)
install -m 0755 "$REPO_PATH/scripts/mail/server_health_check.sh" /usr/local/sbin/server_health_check

# Install ops-monitor config (only if missing; do not clobber real settings)
if [[ ! -f /etc/ops-monitor/ops.conf ]]; then
  install -m 0644 "$REPO_PATH/config/ops-monitor/ops.conf" /etc/ops-monitor/ops.conf
  ok "Created /etc/ops-monitor/ops.conf (edit OPS_TO/OPS_FROM)"
else
  warn "Keeping existing /etc/ops-monitor/ops.conf"
fi

# Install role overlays (safe to overwrite from repo templates)
install -m 0644 "$REPO_PATH/config/ops-monitor/roles/"*.conf /etc/ops-monitor/roles/ 2>/dev/null || true

# Set server role (before installing systemd units)
SERVER_ROLE="${SERVER_ROLE:-base}"
echo "$SERVER_ROLE" > /etc/ops-monitor/role
chmod 0644 /etc/ops-monitor/role

provision_mail() {
  step "Running MAIL role provisioning"

  # ---------------------------------------------------------
  # Mail-specific packages (msmtp already installed in base)
  # ---------------------------------------------------------
  apt-get update -y
  apt-get remove -y docker.io containerd runc docker-compose || true
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

  # ---------------------------------------------------------
  # Mailcow / Docker maintenance scripts
  # ---------------------------------------------------------
  step "Installing Mailcow maintenance scripts"

  install -m 0755 "$REPO_PATH/scripts/mail/mailcow-health-email.sh" \
    /usr/local/bin/mailcow-health-email.sh

  install -m 0755 "$REPO_PATH/scripts/mail/docker-clean.sh" \
    /usr/local/bin/docker-clean.sh

  install -m 0755 "$REPO_PATH/scripts/mail/mailcow-year-archive.sh" \
    /usr/local/bin/mailcow-year-archive.sh

  install -m 0755 "$REPO_PATH/scripts/mail/domain-warmup.sh" \
    /usr/local/bin/domain-warmup.sh

  # ---------------------------------------------------------
  # Mail maintenance cron (managed file, not crontab -e)
  # ---------------------------------------------------------
  step "Installing Mail maintenance cron"

  cat > /etc/cron.d/mail-maint <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

0 */2 * * * root /usr/local/bin/domain-warmup.sh >> /var/log/domain-warmup.log 2>&1
0 6 * * 1 root /usr/local/bin/mailcow-health-email.sh >> /var/log/mailcow-health-email.log 2>&1
0 3 * * * root /usr/local/bin/docker-clean.sh >> /var/log/docker-clean.log 2>&1
0 4 * * 0 root /usr/bin/docker system prune -af >/dev/null 2>&1
0 5 * * 0 root /usr/bin/docker volume prune -f >/dev/null 2>&1
0 3 * * * root /usr/local/bin/mailcow-year-archive.sh >> /var/log/mailcow-year-archive.log 2>&1
20 1 26 3 * root docker compose -f /opt/mailcow-dockerized/docker-compose.yml exec acme-mailcow acme-mailcow --force >> /var/log/acme-retry.log 2>&1
EOF

  chmod 0644 /etc/cron.d/mail-maint

step "Removing legacy Mailcow cron jobs from root crontab"

if crontab -l 2>/dev/null | grep -E -q 'domain-warmup\.sh|mailcow-health-email\.sh|docker-clean\.sh|mailcow-year-archive\.sh|acme-mailcow|prune'; then
  crontab -l | grep -Ev \
    'domain-warmup\.sh|mailcow-health-email\.sh|docker-clean\.sh|mailcow-year-archive\.sh|acme-mailcow|prune' \
    | crontab -
fi


  # ---------------------------------------------------------
  # Remove legacy monitoring cron (replaced by systemd)
  # ---------------------------------------------------------
  if crontab -l 2>/dev/null | grep -q 'server_health_check'; then
    crontab -l | grep -v 'server_health_check' | crontab -
  fi

  if crontab -l 2>/dev/null | grep -q 'mail_server_health_check'; then
    crontab -l | grep -v 'mail_server_health_check' | crontab -
  fi

  ok "MAIL role provisioning complete"
}

provision_web() {
  step "Running WEB role provisioning"

  # ---------------------------------------------------------
  # Web firewall ports (base already allows SSH_PORT)
  # ---------------------------------------------------------
  step "Allowing HTTP/HTTPS through UFW"
  ufw allow 80/tcp
  ufw allow 443/tcp

  step "Configuring firewalld for web (HTTP/HTTPS + SSH)"

  # Ensure firewalld is running
  systemctl enable --now firewalld

# Allow HTTP/HTTPS permanently
firewall-cmd --permanent --add-service=http
firewall-cmd --permanent --add-service=https

# SSH: either allow the ssh service...
firewall-cmd --permanent --add-service=ssh

# ...or if you use a custom SSH port, open it explicitly instead:
# firewall-cmd --permanent --add-port="${SSH_PORT}/tcp"

firewall-cmd --reload


  # ---------------------------------------------------------
  # Web-specific packages (Docker like mail role)
  # ---------------------------------------------------------
  apt-get update -y
  apt-get remove -y docker.io containerd runc docker-compose || true
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

  # ---------------------------------------------------------
  # Optional: Docker maintenance script (reuse existing one)
  # ---------------------------------------------------------
  step "Installing Docker maintenance script"

  install -m 0755 "$REPO_PATH/scripts/mail/docker-clean.sh" \
    /usr/local/bin/docker-clean.sh

  # ---------------------------------------------------------
  # Web maintenance cron (managed file, not crontab -e)
  # ---------------------------------------------------------
  step "Installing Web maintenance cron"

  cat > /etc/cron.d/web-maint <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

0 3 * * * root /usr/local/bin/docker-clean.sh >> /var/log/docker-clean.log 2>&1
0 4 * * 0 root /usr/bin/docker system prune -af >/dev/null 2>&1
0 5 * * 0 root /usr/bin/docker volume prune -f >/dev/null 2>&1
EOF

  chmod 0644 /etc/cron.d/web-maint

  # ---------------------------------------------------------
  # Cleanup: remove mail cron if this host is NOT mail
  # ---------------------------------------------------------
  step "Removing Mail maintenance cron (if present)"
  rm -f /etc/cron.d/mail-maint 2>/dev/null || true

  # ---------------------------------------------------------
  # Remove legacy related cron entries from root crontab
  # ---------------------------------------------------------
  step "Removing legacy maintenance cron jobs from root crontab"
  if crontab -l 2>/dev/null | grep -E -q 'docker-clean\.sh|docker system prune|docker volume prune'; then
    crontab -l | grep -Ev \
      'docker-clean\.sh|docker system prune|docker volume prune' \
      | crontab -
  fi

  ok "WEB role provisioning complete"
}

# ---------------------------------------------------------
# INSTALL SYSTEMD UNITS
# ---------------------------------------------------------
step "Installing systemd timer units"
install -m 0644 "$REPO_PATH/scripts/ops-monitor/systemd/ops-threshold-check.service" /etc/systemd/system/ops-threshold-check.service
install -m 0644 "$REPO_PATH/scripts/ops-monitor/systemd/ops-threshold-check.timer"   /etc/systemd/system/ops-threshold-check.timer
install -m 0644 "$REPO_PATH/scripts/ops-monitor/systemd/ops-weekly-summary.service" /etc/systemd/system/ops-weekly-summary.service
install -m 0644 "$REPO_PATH/scripts/ops-monitor/systemd/ops-weekly-summary.timer"   /etc/systemd/system/ops-weekly-summary.timer

# Enable timers
systemctl daemon-reload
systemctl enable --now ops-threshold-check.timer ops-weekly-summary.timer

ok "ops-monitor installed (role=${SERVER_ROLE})"


# ---------------------------------------------------------
# MONITORING SCHEDULING
# ---------------------------------------------------------
# Monitoring is handled via systemd timers:
#  - ops-threshold-check.timer (every 5 minutes)
#  - ops-weekly-summary.timer (weekly)
# Cron is intentionally NOT used.
rm -f /etc/cron.d/server_health_check || true

# ---------------------------------------------------------
# OUTPUT PRIVATE SSH KEY
# ---------------------------------------------------------

rule
banner "🔐 SSH PRIVATE KEY FOR $ADMIN_USER"
rule
echo
cat /home/$ADMIN_USER/.ssh/id_ed25519
echo
echo "SAVE THIS KEY NOW — YOU WILL NOT SEE IT AGAIN"
echo "======================================================="

case "$SERVER_ROLE" in
  mail) provision_mail ;;
  web)  provision_web ;;
  base) : ;;
  *)    warn "Unknown SERVER_ROLE='$SERVER_ROLE' (no role-specific steps run)" ;;
esac

rule
ok "Provisioning complete!"
banner "User: $ADMIN_USER"
banner "SSH Port: $SSH_PORT"
banner "Monitoring: ops-monitor (role=${SERVER_ROLE})"
banner "Linode CLI: pipx-installed"
banner "Snap: REMOVED & BLOCKED"
banner "Log file: ${LOG_FILE}"
rule
