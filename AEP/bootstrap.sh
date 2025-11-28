#!/bin/bash
set -e

REPO_URL="https://github.com/Alter-Ego-Technologies/ae_provisioning.git"
TARGET_DIR="/root/ae_provisioning"

apt update -y
apt install -y git

if [ ! -d "$TARGET_DIR" ]; then
  git clone "$REPO_URL" "$TARGET_DIR"
else
  cd "$TARGET_DIR"
  git pull
fi

cd "$TARGET_DIR"
bash ./provision.sh
