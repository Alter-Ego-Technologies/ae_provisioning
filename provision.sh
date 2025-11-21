#!/bin/bash
set -e

# --- VARIABLES ---
USERNAME="gabe"
SSH_PORT="2222"

echo "==> Updating system"
apt update -y && apt upgrade -y

echo "==> Creating user: $USERNAME"
adduser --disabled-password --gecos "" $USERNAME

echo "==> Allowing passwordless sudo"
usermod -aG sudo $USERNAME
echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-$USERNAME
chmod 440 /etc/sudoers.d/90-$USERNAME

echo "==> Creating SSH directory & keys for user"
mkdir -p /home/$USERNAME/.ssh
chmod 700 /home/$USERNAME/.ssh

# Generate keys
echo "==> Generating SSH keys"
ssh-keygen -t ed25519 -f /home/$USERNAME/.ssh/id_ed25519 -N "" -C "$USERNAME@$(hostname)"

# Authorize user key
cat /home/$USERNAME/.ssh/id_ed25519.pub > /home/$USERNAME/.ssh/authorized_keys
chmod 600 /home/$USERNAME/.ssh/authorized_keys
chown -R $USERNAME:$USERNAME /home/$USERNAME/.ssh

echo "==> Fixing SSH privilege separation directory"
mkdir -p /run/sshd
chmod 755 /run/sshd

echo "==> Hardening sshd_config and setting port $SSH_PORT"

# Remove existing Port lines, add one fresh
sed -i '/^[Pp]ort /d' /etc/ssh/sshd_config
echo "Port $SSH_PORT" >> /etc/ssh/sshd_config

# Disable password login & root login
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config

# Ensure PubkeyAuthentication is enabled
sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config

echo "==> Validating SSH configuration"
if ! sshd -t; then
    echo "ERROR: sshd configuration invalid. Aborting."
    exit 1
fi

echo "==> Restarting SSH"
systemctl restart ssh

echo "==> Installing and configuring UFW"
apt install ufw -y
ufw default deny incoming
ufw default allow outgoing
ufw allow $SSH_PORT/tcp
ufw --force enable

echo "======================================================="
echo "                SSH PRIVATE KEY BELOW"
echo "======================================================="
echo
cat /home/$USERNAME/.ssh/id_ed25519
echo
echo "======================================================="
echo "Copy the above PRIVATE KEY into a file on your computer."
echo "Save as: id_ed25519"
echo "Then convert using PuTTYgen if needed."
echo "======================================================="
