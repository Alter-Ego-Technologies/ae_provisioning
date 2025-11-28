#!/bin/bash
set -e

REPO_URL="https://github.com/YOUR_GITHUB_USER/linode-bootstrap.git"
TARGET_DIR="/root/linode-bootstrap"

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
