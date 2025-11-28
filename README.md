# 📦 AEP — Alter Ego Provisioning
Automated server provisioning, security hardening, and baseline system setup for all Alter Ego infrastructure.

AEP provides a repeatable, Git-driven, fully automated bootstrap process for new Linux servers.  
It standardizes every new server deployment across Alter Ego.

---

# 🚀 What AEP Does

## 🔐 Security + User Setup
- Creates privileged superuser: `gabe`
- Enables passwordless sudo
- Generates SSH keypair for the new user
- Enforces key-only SSH
- Disables root SSH login
- Moves SSH from `22` → `2222`
- Ensures SSH privilege separation directory (`/run/sshd`)
- Validates SSH config before restart
- Enables UFW firewall
- Allows only port `2222`

---

## 📧 Monitoring + Alerts
AEP installs Alter Ego’s standardized health monitoring system:

- CPU load monitoring (per-core threshold)
- Disk usage monitoring
- Memory usage monitoring
- Customizable alert thresholds
- Detailed email alerts for abnormal conditions
- Weekly summary email report

### Cron Jobs
- */5 * * * * server_health_check.sh
- 0 9 * * SUN server_health_check.sh summary\n

Alerts go to:
- server-alerts@alteregotech.com
- admins@clearpointreporting.com

## 📨 SMTP Relay Configuration
AEP installs and configures `msmtp` for alert delivery.  
Password is placeholder and must be updated post-install.

# 📂 Repository Structure
AEP/
├── provision.sh # Main provisioning automation
├── bootstrap.sh # One-line installer
├── scripts/
│ └── server_health_check.sh # Alert + summary monitoring
├── config/
│ └── msmtprc # SMTP relay config
└── README.md

# 🏗️ Deploying AEP on a New Server

# Install Git + Clone Repo
```bash
cd /root
apt update -y
apt install -y git
git clone https://github.com/Alter-Ego-Technologies/ae_provisioning.git
cd AEP
