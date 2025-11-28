#!/bin/bash
set -e

# Determine repo path based on where this script lives
REPO_PATH="$(cd "$(dirname "$0")" && pwd)"

USERNAME="gabe"
SSH_PORT="2222"

echo "==> Running provisioning from Git repo: $REPO_PATH"

echo "==> Updating system"
apt update -y && apt upgrade -y

echo "==> Installing base packages (firewall, mail, tools)"
apt install -y ufw msmtp msmtp-mta ca-certificates bsd-mailx bc git

echo "==> Creating user: $USERNAME"
if ! id "$USERNAME" &>/dev/null; then
  adduser --disabled-password --gecos "" "$USERNAME"
fi

echo "==> Allowing passwordless sudo for $USERNAME"
usermod -aG sudo "$USERNAME"
echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-"$USERNAME"
chmod 440 /etc/sudoers.d/90-"$USERNAME"

echo "==> Creating SSH directory & keys for user"
mkdir -p /home/"$USERNAME"/.ssh
chmod 700 /home/"$USERNAME"/.ssh

if [ ! -f /home/"$USERNAME"/.ssh/id_ed25519 ]; then
  echo "==> Generating SSH keys for $USERNAME"
  ssh-keygen -t ed25519 -f /home/"$USERNAME"/.ssh/id_ed25519 -N "" -C "$USERNAME@$(hostname)"
fi

cat /home/"$USERNAME"/.ssh/id_ed25519.pub > /home/"$USERNAME"/.ssh/authorized_keys
chmod 600 /home/"$USERNAME"/.ssh/authorized_keys
chown -R "$USERNAME":"$USERNAME" /home/"$USERNAME"/.ssh

echo "==> Ensuring SSH privilege separation directory exists"
/bin/mkdir -p /run/sshd
chmod 755 /run/sshd

echo "==> Hardening sshd_config and setting port $SSH_PORT"

# Remove existing Port lines, add one fresh
sed -i '/^[Pp]ort /d' /etc/ssh/sshd_config
echo "Port $SSH_PORT" >> /etc/ssh/sshd_config

# Disable password login & root login
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config || true
sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config || true

sed -i 's/#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config || true
sed -i 's/PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config || true

# Ensure PubkeyAuthentication is enabled
sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config || true

echo "==> Validating SSH configuration"
if ! sshd -t; then
    echo "ERROR: sshd configuration invalid. Aborting."
    exit 1
fi

echo "==> Restarting SSH"
systemctl restart ssh

echo "==> Configuring UFW firewall"
ufw default deny incoming
ufw default allow outgoing
ufw allow "$SSH_PORT"/tcp
ufw --force enable

# --------------------------------------------------
# msmtp configuration (from repo)
# --------------------------------------------------
echo "==> Installing msmtp config from $REPO_PATH/config/msmtprc"
install -m 600 "$REPO_PATH/config/msmtprc" /etc/msmtprc

touch /var/log/msmtp.log
chmod 640 /var/log/msmtp.log || true

# --------------------------------------------------
# Install server monitoring script
# --------------------------------------------------
echo "==> Installing server health monitoring script"
install -m 755 "$REPO_PATH/scripts/server_health_check.sh" /usr/local/bin/server_health_check.sh

touch /var/log/server_health.log
chmod 644 /var/log/server_health.log

# --------------------------------------------------
# Cron: every 5 minutes + weekly summary
# --------------------------------------------------
echo "==> Creating cron entries for monitoring"

cat > /etc/cron.d/server_health_check << 'EOF'
*/5 * * * * root /usr/local/bin/server_health_check.sh
0 9 * * SUN root /usr/local/bin/server_health_check.sh summary
EOF

chmod 644 /etc/cron.d/server_health_check

# --------------------------------------------------
# Show SSH private key (for grabbing via console)
# --------------------------------------------------
echo "======================================================="
echo "                SSH PRIVATE KEY BELOW"
echo "======================================================="
echo
cat /home/"$USERNAME"/.ssh/id_ed25519
echo
echo "======================================================="
echo "Copy the above PRIVATE KEY into a file on your computer."
echo "Save as: id_ed25519 and protect it."
echo "======================================================="

echo
echo "==> Provisioning complete!"
echo "SSH port: $SSH_PORT"
echo "User: $USERNAME"
echo "Monitoring: /usr/local/bin/server_health_check.sh"
echo "Cron: /etc/cron.d/server_health_check"
echo "Remember to edit /etc/msmtprc and set the real SMTP password."
