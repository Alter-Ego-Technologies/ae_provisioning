#!/bin/bash
set -e
clear

# Resolve repo root robustly (works whether provision.sh is in repo root or inside AEP/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_PATH="${SCRIPT_DIR}"

# Colors and emoji helpers (disable with NO_COLOR=1 or when not a TTY)
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  CYAN="\033[1;36m"; GREEN="\033[1;32m"; YELLOW="\033[1;33m"; RED="\033[1;31m"; BOLD="\033[1m"; RESET="\033[0m"
else
  CYAN=""; GREEN=""; YELLOW=""; RED=""; BOLD=""; RESET=""
fi

# Interactive prompt for server role if not set

if [[ -z "${SERVER_ROLE:-}" ]]; then
  echo -e "${CYAN}Select server role to provision:${RESET}"
  echo -e "  ${GREEN}1)${RESET} ${BOLD}Base ${RESET} - Minimal system setup, no app stack"
  echo -e "  ${GREEN}2)${RESET} ${BOLD}Mail ${RESET} - Mail server (Mailcow, postfix, dovecot, etc.)"
  echo -e "  ${GREEN}3)${RESET} ${BOLD}CyberPanel ${RESET} - CyberPanel-managed web hosting (web, users, DBs)"
  echo -e "  ${GREEN}4)${RESET} ${BOLD}Custom Apps & Services ${RESET} - Standalone code, apps, or services (not managed by CyberPanel). For static sites, dev tools, custom web apps, scripts, and any non-panel projects."
  echo -e "  ${GREEN}5)${RESET} ${BOLD}WebCyberPanel${RESET} - Both CyberPanel and custom apps together"
  echo -e "  ${GREEN}6)${RESET} ${BOLD}Nextcloud ${RESET} - Nextcloud file server stack"
  echo -e "  ${GREEN}7)${RESET} ${BOLD}Backup ${RESET} - Dedicated backup server (runs all backup scripts/crons)"
  echo -e "  ${RED}0)${RESET} Quit"
  echo
    read -p "Enter number [0-7]: " REPLY
  case $REPLY in
      0) echo "Quitting."; exit 0 ;;
    1) SERVER_ROLE="Base" ;;
    2) SERVER_ROLE="Mail" ;;
    3) SERVER_ROLE="CyberPanel" ;;
    4) SERVER_ROLE="standalone" ;;
    5) SERVER_ROLE="WebCyberPanel" ;;
    6) SERVER_ROLE="Nextcloud" ;;
    7) SERVER_ROLE="Backup" ;;
    *) echo "Invalid selection"; exit 1 ;;
  esac
  export SERVER_ROLE
fi

# Prompt for hostname if not set or if user wants to edit
CURRENT_HOSTNAME=$(hostname)
if [[ -z "${HOSTNAME_OVERRIDE:-}" ]]; then
  echo "Current hostname is: $CURRENT_HOSTNAME"
  read -p "Enter hostname to set (leave blank to keep current): " NEW_HOSTNAME
  if [[ -n "$NEW_HOSTNAME" ]]; then
    hostnamectl set-hostname "$NEW_HOSTNAME"
    export HOSTNAME_OVERRIDE="$NEW_HOSTNAME"
    echo "Hostname set to $NEW_HOSTNAME"
  else
    export HOSTNAME_OVERRIDE="$CURRENT_HOSTNAME"
    echo "Keeping current hostname: $CURRENT_HOSTNAME"
  fi
fi

# Configuration from environment or defaults
ADMIN_USER="${ADMIN_USER:-gabe}"
SSH_PORT="${SSH_PORT:-2222}"
LOG_FILE="${LOG_FILE:-/var/log/provision.log}"

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

ok "Linode CLI installed successfully"

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

# Ensure docker group exists before adding user
if ! getent group docker >/dev/null; then
  groupadd docker
fi

# ---------------------------------------------------------
# CREATE USER & SSH SETUP
# ---------------------------------------------------------
if id -u "$ADMIN_USER" >/dev/null 2>&1; then
  ok "User '$ADMIN_USER' already exists, skipping creation"
  # Check if home directory is missing or empty - if so, recreate it
  if [ ! -d "/home/$ADMIN_USER" ] || [ ! -f "/home/$ADMIN_USER/.bashrc" ]; then
    warn "Home directory missing or incomplete, recreating..."
    # Remove user without deleting home (in case it's mounted elsewhere)
    userdel "$ADMIN_USER" 2>/dev/null || true
    # Recreate user with home directory
    useradd -m -s /bin/bash "$ADMIN_USER"
    ok "User recreated with fresh home directory"
  fi
else
  step "Creating user '$ADMIN_USER'"
  useradd -m -s /bin/bash "$ADMIN_USER"
fi

BASH_HELPERS_REPO_URL="${BASH_HELPERS_REPO_URL:-git@github.com:Alter-Ego-Technologies/bash-helpers.git}"
BASH_HELPERS_PATH="/opt/bash-helpers"

step "Installing bash dotfiles from bash-helpers"
if [[ ! -d "${BASH_HELPERS_PATH}/bash-dotfiles" ]]; then
  git clone --depth 1 "$BASH_HELPERS_REPO_URL" "$BASH_HELPERS_PATH"
fi

DOTFILES_DIR="${BASH_HELPERS_PATH}/bash-dotfiles"
TARGET_HOME="/home/$ADMIN_USER" TARGET_USER="$ADMIN_USER" \
  bash "$DOTFILES_DIR/install-copy.sh"

# Role-specific: Mail server gets different aliases
if [[ "$SERVER_ROLE" == "Mail" ]]; then
  step "Installing mail server bash aliases"
  install -m 644 "$REPO_PATH/config/bash/mailserver_aliases" "/home/$ADMIN_USER/.bash_aliases"
  chown "$ADMIN_USER:$ADMIN_USER" "/home/$ADMIN_USER/.bash_aliases"
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
    # Only set up authorized_keys if we just created the key
    cat /home/$ADMIN_USER/.ssh/id_ed25519.pub > /home/$ADMIN_USER/.ssh/authorized_keys
    chmod 600 /home/$ADMIN_USER/.ssh/authorized_keys
else
    ok "SSH keypair already exists, skipping generation"
    # Only set up authorized_keys if it doesn't exist
    if [ ! -f "/home/$ADMIN_USER/.ssh/authorized_keys" ]; then
      cat /home/$ADMIN_USER/.ssh/id_ed25519.pub > /home/$ADMIN_USER/.ssh/authorized_keys
      chmod 600 /home/$ADMIN_USER/.ssh/authorized_keys
    fi
fi

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

# ---------------------------------------------------------
# BACKUP ROLE FUNCTION
# ---------------------------------------------------------
provision_backup() {
    BACKUP_ROOT="/mnt/Backups"
    # 3a. Copy example configs to runtime locations if missing
    for service in nextcloud mailcow cyberpanel standalone; do
      example_conf="$REPO_PATH/config/backup/${service}.conf.example"
      dest_conf="$BACKUP_ROOT/${service}/${service}.conf"
      mkdir -p "$BACKUP_ROOT/$service"
      if [ -f "$example_conf" ] && [ ! -f "$dest_conf" ]; then
        cp "$example_conf" "$dest_conf"
        ok "Installed example config for $service at $dest_conf (edit with real values!)"
      fi
    done
  step "Running BACKUP role provisioning"

  # 1. Ensure backup directory structure
  mkdir -p $BACKUP_ROOT/{scripts,logs}
  mkdir -p $BACKUP_ROOT/nextcloud/{data,sql}
  mkdir -p $BACKUP_ROOT/mailcow/backups
  mkdir -p $BACKUP_ROOT/cyberpanel/{home,db}
  mkdir -p $BACKUP_ROOT/standalone

  # Set ownership to ADMIN_USER so backup scripts can run as that user
  chown -R $ADMIN_USER:$ADMIN_USER $BACKUP_ROOT
  chmod 755 $BACKUP_ROOT
  chmod -R 755 $BACKUP_ROOT/{scripts,logs,nextcloud,mailcow,cyberpanel,standalone}

  # 2. Install required tools (rclone for S3/B2 offsite sync)
  apt-get update -y
  apt-get install -y rsync mariadb-client curl unzip rclone

  # 3. Copy remote.conf.example for S3/B2 if missing
  if [ -f "$REPO_PATH/config/backup/remote.conf.example" ] && [ ! -f "$BACKUP_ROOT/remote.conf" ]; then
    cp "$REPO_PATH/config/backup/remote.conf.example" "$BACKUP_ROOT/remote.conf"
    ok "Installed remote.conf at $BACKUP_ROOT/remote.conf (see config/backup/SETUP_B2.md for B2 setup; edit RCLONE_REMOTE and run rclone config)"
  fi

  # 3b. Copy notify.conf.example for backup email notifications if missing
  if [ -f "$REPO_PATH/config/backup/notify.conf.example" ] && [ ! -f "$BACKUP_ROOT/notify.conf" ]; then
    cp "$REPO_PATH/config/backup/notify.conf.example" "$BACKUP_ROOT/notify.conf"
    chown $ADMIN_USER:$ADMIN_USER "$BACKUP_ROOT/notify.conf"
    ok "Installed notify.conf at $BACKUP_ROOT/notify.conf (edit BACKUP_NOTIFY_TO for recipients)"
  fi

  # 4. Install backup scripts from repo
  install -m 0755 "$REPO_PATH/scripts/backup/sync_nextcloud.sh" $BACKUP_ROOT/scripts/sync_nextcloud.sh
  install -m 0755 "$REPO_PATH/scripts/backup/sync_mailcow.sh" $BACKUP_ROOT/scripts/sync_mailcow.sh
  install -m 0755 "$REPO_PATH/scripts/backup/sync_cyberpanel.sh" $BACKUP_ROOT/scripts/sync_cyberpanel.sh
  install -m 0755 "$REPO_PATH/scripts/backup/sync_standalone.sh" $BACKUP_ROOT/scripts/sync_standalone.sh
  install -m 0755 "$REPO_PATH/scripts/backup/sync_all_web.sh" $BACKUP_ROOT/scripts/sync_all_web.sh
  install -m 0755 "$REPO_PATH/scripts/backup/sync_to_cloud.sh" $BACKUP_ROOT/scripts/sync_to_cloud.sh
  install -m 0755 "$REPO_PATH/scripts/backup/backup_notify.sh" $BACKUP_ROOT/scripts/backup_notify.sh
  install -m 0755 "$REPO_PATH/scripts/backup/backup_mailcow_daily_summary.sh" $BACKUP_ROOT/scripts/backup_mailcow_daily_summary.sh

  # Also install to /usr/local/bin for global access
  install -m 0755 "$REPO_PATH/scripts/backup/sync_nextcloud.sh" /usr/local/bin/sync_nextcloud.sh
  install -m 0755 "$REPO_PATH/scripts/backup/sync_mailcow.sh" /usr/local/bin/sync_mailcow.sh
  install -m 0755 "$REPO_PATH/scripts/backup/sync_cyberpanel.sh" /usr/local/bin/sync_cyberpanel.sh
  install -m 0755 "$REPO_PATH/scripts/backup/sync_standalone.sh" /usr/local/bin/sync_standalone.sh
  install -m 0755 "$REPO_PATH/scripts/backup/sync_all_web.sh" /usr/local/bin/sync_all_web.sh
  install -m 0755 "$REPO_PATH/scripts/backup/sync_to_cloud.sh" /usr/local/bin/sync_to_cloud.sh
  install -m 0755 "$REPO_PATH/scripts/backup/backup_notify.sh" /usr/local/bin/backup_notify.sh
  install -m 0755 "$REPO_PATH/scripts/backup/backup_mailcow_daily_summary.sh" /usr/local/bin/backup_mailcow_daily_summary.sh

  ok "BACKUP role provisioning complete"

  # 5. Install managed cron for backup scripts
  step "Installing backup cron schedule"
  cat > /etc/cron.d/backup-maint <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Mailcow: every hour
0 * * * * ${ADMIN_USER} /mnt/Backups/scripts/sync_mailcow.sh >> /mnt/Backups/logs/mailcow-cron.log 2>&1
# Nextcloud: nightly at 2:15
15 2 * * * ${ADMIN_USER} /mnt/Backups/scripts/sync_nextcloud.sh >> /mnt/Backups/logs/nextcloud-cron.log 2>&1
# CyberPanel: nightly at 3:15
15 3 * * * ${ADMIN_USER} /mnt/Backups/scripts/sync_cyberpanel.sh >> /mnt/Backups/logs/cyberpanel-cron.log 2>&1
# Standalone: nightly at 4:15
15 4 * * * ${ADMIN_USER} /mnt/Backups/scripts/sync_standalone.sh >> /mnt/Backups/logs/standalone-cron.log 2>&1
# S3/B2 offsite: nightly at 5:15 (after all local backups complete)
15 5 * * * ${ADMIN_USER} /mnt/Backups/scripts/sync_to_cloud.sh >> /mnt/Backups/logs/cloud-cron.log 2>&1
# Mailcow backup daily summary (one email/day instead of hourly)
0 6 * * * ${ADMIN_USER} /mnt/Backups/scripts/backup_mailcow_daily_summary.sh >> /mnt/Backups/logs/mailcow-summary-cron.log 2>&1
EOF
  chmod 0644 /etc/cron.d/backup-maint
  ok "Backup cron schedule installed"
}

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

provision_standalone() {
  step "Custom Apps & Services provisioning"

  # Custom apps/services firewall ports (base already allows SSH_PORT)
  step "Allowing HTTP/HTTPS/SMTP through UFW (for custom apps/services)"
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw allow out 25/tcp    # SMTP (alert relay to mail server)
  ufw allow out 587/tcp   # SMTP + STARTTLS

  # Remove legacy related cron entries from root crontab
  step "Removing legacy maintenance cron jobs from root crontab"
  if crontab -l 2>/dev/null | grep -E -q 'docker-clean\.sh|docker system prune|docker volume prune'; then
    crontab -l | grep -Ev 'docker-clean\.sh|docker system prune|docker volume prune' | crontab -
  fi

  mkdir -p /mnt/web/standalone
  chown $ADMIN_USER:$ADMIN_USER /mnt/web/standalone
  mkdir -p /opt/standalone
  chown $ADMIN_USER:$ADMIN_USER /opt/standalone
  mount --bind /mnt/web/standalone /opt/standalone
  if ! grep -q "/mnt/web/standalone" /etc/fstab; then
    echo "/mnt/web/standalone /opt/standalone none bind 0 0" >> /etc/fstab
  fi  
    ok "Custom Apps & Services role provisioning complete"
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

provision_nextcloud() {
  step "Running NEXTCLOUD role provisioning"
  # Pull required images
  docker pull nextcloud
  docker pull mariadb:10.6

  # Create external volumes if not present
  docker volume inspect nextcloud_data >/dev/null 2>&1 || docker volume create nextcloud_data
  docker volume inspect nextcloud_db >/dev/null 2>&1 || docker volume create nextcloud_db

  # Start containers using docker-compose (if available)
  if [ -f /opt/nextcloud/docker-compose.yml ]; then
    step "Starting Nextcloud stack via docker compose..."
    docker compose -f /opt/nextcloud/docker-compose.yml up -d
  else
    err "docker-compose.yml not found. Please place it at /opt/nextcloud/docker-compose.yml."
    exit 1
  fi

  ok "NEXTCLOUD role provisioning complete"
}
rule
banner "🔐 SSH PRIVATE KEY FOR $ADMIN_USER"
rule
echo

cat /home/$ADMIN_USER/.ssh/id_ed25519


provision_cyberpanel() {
  step "Running CYBERPANEL role provisioning"

  # Open CyberPanel and web ports
  step "Allowing CyberPanel and web ports through UFW"
  ufw allow 8090/tcp   # CyberPanel admin
  ufw allow 80/tcp     # HTTP
  ufw allow 443/tcp    # HTTPS
  ufw allow 21/tcp     # FTP
  ufw allow 25/tcp     # SMTP
  ufw allow 587/tcp    # SMTP submission
  ufw allow 465/tcp    # SMTPS
  ufw allow 53/tcp     # DNS
  ufw allow 53/udp     # DNS
  ufw allow 3306/tcp   # MariaDB/MySQL (optional, restrict as needed)

  mkdir -p /mnt/web/Websites
  chown nobody:nogroup /mnt/web/Websites
  mount --bind /mnt/web/Websites /home
  if ! grep -q "/mnt/web/Websites" /etc/fstab; then
    echo "/mnt/web/Websites /home none bind 0 0" >> /etc/fstab
  fi

  # Install or update CyberPanel without affecting user data
  if command -v cyberpanel >/dev/null 2>&1 || [ -d "/usr/local/CyberCP" ]; then
    step "Updating CyberPanel (safe upgrade, data preserved)"
    wget -O /tmp/cyberpanel_install.sh https://cyberpanel.net/install.sh
    # Suppress only 'Unknown argument...' and help text
    bash /tmp/cyberpanel_install.sh --upgrade 2>&1 | awk '/Unknown argument/ {skip=1} /CyberPanel Installer Script Help/ {exit} !skip {print}'
    rm -f /tmp/cyberpanel_install.sh
    ok "CyberPanel updated (user data preserved)"
  else
    step "Installing CyberPanel (fresh install)"
    wget -O /tmp/cyberpanel_install.sh https://cyberpanel.net/install.sh
    bash /tmp/cyberpanel_install.sh
    rm -f /tmp/cyberpanel_install.sh
    ok "CyberPanel installed"
  fi

  ok "CYBERPANEL role provisioning complete"
}

case "$SERVER_ROLE" in
  Mail) provision_mail ;;
  standalone)  provision_standalone ;;
  CyberPanel) provision_cyberpanel ;;
  WebCyberPanel) provision_standalone; provision_cyberpanel ;;
  Nextcloud) provision_nextcloud ;;
  Backup) provision_backup ;;
  Base) : ;;
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
