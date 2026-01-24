# 📦 AEP — Alter Ego Provisioning

Automated server bootstrap, provisioning, and operational monitoring for all Alter Ego infrastructure.

AEP provides a **repeatable, Git-driven, idempotent** process for building and operating Linux servers.  
It standardizes security posture, system configuration, and health monitoring across all hosts.

---

## 🚀 What AEP Does

### 🔐 Security + Base System Setup
- Creates privileged superuser: `gabe`
- Enables passwordless sudo
- Generates SSH keypair for the new user
- Enforces key-only SSH authentication
- Disables root SSH login
- Moves SSH from port `22` → `2222`
- Ensures SSH privilege separation directory (`/run/sshd`)
- Validates SSH configuration before restart
- Enables UFW firewall
- Allows only required ports (default: `2222`)

---

### 🧩 Bootstrap vs Provisioning

AEP is intentionally split into **two phases**:

#### `bootstrap.sh`
- Run **once** on a brand-new server
- Installs minimal prerequisites (git, sudo, etc.)
- Performs initial OS hardening
- Clones this repository

This script should rarely change.

#### `provision.sh`
- Main configuration entrypoint
- **Safe to re-run** at any time
- Applies server role (`mail`, `web`, `db`, `worker`, `base`)
- Installs and updates monitoring
- Used after `git pull` to apply changes

---

## 🖥️ Server Roles

Servers are assigned a role, which controls:
- required services
- monitoring checks
- alert thresholds
- weekly summary content

Supported roles:
- `base`   – core system checks only
- `mail`   – postfix/dovecot + mail queue monitoring
- `web`    – nginx and web stack
- `db`     – database services
- `worker` – background job processors

The active role is stored at:
```
/etc/ops-monitor/role
```

Example:
```bash
SERVER_ROLE=mail sudo ./provision.sh
```

---

## 📧 Monitoring + Alerts (Ops Monitor)

AEP installs Alter Ego’s **standardized monitoring system** located in:

```
scripts/ops-monitor/
```

### Features
- Threshold-based alerts:
  - disk usage
  - memory usage
  - CPU usage (averaged)
  - load average (per-core)
  - required services
  - mail queue + deferred messages (mail role)
- Stateful alerting (emails only on change or cooldown)
- Weekly operational summary email
- Role-aware checks
- Uses **systemd timers** (no cron)

### Email Delivery
- Alerts and summaries are sent via `/usr/sbin/sendmail`
- Assumes postfix is relaying through the mail server
- `msmtprc` is present for compatibility but not required by ops-monitor

---

### ⏱️ Timers (systemd)
- Threshold checks: every 5 minutes
- Weekly summary: Monday at 08:00 local time

Timers installed:
```
ops-threshold-check.timer
ops-weekly-summary.timer
```

---

### ⚙️ Configuration

Global configuration:
```
/etc/ops-monitor/ops.conf
```

Role defaults:
```
/etc/ops-monitor/roles/
```

Optional per-host overrides:
```
/etc/ops-monitor/local.conf
```

Monitoring state:
```
/var/lib/ops-monitor/
```

---

### 🧪 Legacy Health Checks

The existing script:
```
scripts/server_health_check.sh
```

is still executed and included in the **weekly summary** to preserve existing visibility during migration.

---

## 📂 Repository Structure

```
.
├── bootstrap.sh                # One-time server bootstrap
├── provision.sh                # Main provisioning entrypoint
├── scripts/
│   ├── server_health_check.sh  # Legacy health checks
│   └── ops-monitor/            # Monitoring & alerting bundle
├── config/
│   ├── msmtprc                 # SMTP config (optional)
│   └── ops-monitor/            # Monitoring configs & role overlays
└── README.md
```

---

## 🏗️ Deploying AEP on a New Server

### 1️⃣ Bootstrap (run once)
```bash
apt update -y
apt install -y git
git clone https://github.com/Alter-Ego-Technologies/ae_provisioning.git
cd ae_provisioning
sudo ./bootstrap.sh
```

### 2️⃣ Provision
```bash
SERVER_ROLE=base sudo ./provision.sh
```

Example mail server:
```bash
SERVER_ROLE=mail sudo ./provision.sh
```

---

## 🔄 Updating a Server

```bash
cd /opt/ae_provisioning
git pull
sudo ./provision.sh
```

Provisioning and monitoring updates are applied safely.

---

## 🧠 Design Principles

- Bootstrap once, provision forever
- Monitoring is uniform across all servers
- Roles define behavior, not snowflake hosts
- Everything should be understandable at 2am
- Git is the source of truth

---

## 🔮 Future Improvements
- Split ops-monitor into its own repository
- Optional Slack / PagerDuty integrations
- Backup success verification
- Automatic TLS certificate discovery
