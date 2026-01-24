#!/bin/bash
# Server Health Monitor - Disk + Memory + CPU + Volumes
# Usage:
#   ./server_health_check.sh            → Alert mode (thresholds)
#   ./server_health_check.sh summary    → Weekly summary (no thresholds)

THRESHOLD_DISK=${THRESHOLD_DISK:-85}
THRESHOLD_MEM=${THRESHOLD_MEM:-90}
THRESHOLD_CPU=${THRESHOLD_CPU:-2.0}

ALERT_EMAIL="server-alerts@alteregotech.com,admins@clearpointreporting.com"
MODE=$1

HOST="Alter Ego Web Server"
DATE=$(date "+%Y-%m-%d %H:%M:%S")
ALERT=0

MSG="Server: $HOST
Date: $DATE
----------------------------------------------------------"

# ===== Memory =====
MEM_USE=$(free | awk '/Mem:/ {printf("%.0f"), $3/$2*100}')

if [ "$MODE" == "summary" ]; then
    MSG+="
Memory usage: ${MEM_USE}%"
else
    if [ "$MEM_USE" -ge "$THRESHOLD_MEM" ]; then
        MSG+="
⚠️  Memory usage is high: ${MEM_USE}% (Threshold ${THRESHOLD_MEM}%)"
        ALERT=1
    else
        MSG+="
✅ Memory usage OK: ${MEM_USE}%"
    fi
fi

# ===== Disk =====
MSG+="
----------------------------------------------------------
Filesystem usage:"

while read -r USE MOUNT; do
    USE=${USE%\%}
    LINE="  $MOUNT = ${USE}% used"

    if [ "$MODE" == "summary" ]; then
        MSG+="
$LINE"
    else
        if [ "$USE" -ge "$THRESHOLD_DISK" ]; then
            MSG+="
$LINE ⚠️ Above ${THRESHOLD_DISK}%"
            ALERT=1
        else
            MSG+="
$LINE"
        fi
    fi
done < <(df -h -x tmpfs -x devtmpfs -x overlay | awk 'NR>1 {print $5, $6}')

# ===== CPU =====
CORES=$(nproc)
LOAD=$(awk '{print $1}' /proc/loadavg)
LIMIT=$(echo "$CORES * $THRESHOLD_CPU" | bc)
IS_HIGH=$(echo "$LOAD > $LIMIT" | bc)

MSG+="
----------------------------------------------------------
CPU load: $LOAD (cores: $CORES, limit: $LIMIT)"

if [ "$MODE" == "summary" ]; then
    :
elif [ "$IS_HIGH" -eq 1 ]; then
    MSG+=" ⚠️ High CPU load!"
    ALERT=1
else
    MSG+=" ✅"
fi

# =============================
# SEND EMAIL / LOG
# =============================

if [ "$MODE" == "summary" ]; then
cat <<REPORT | msmtp -t
To: $ALERT_EMAIL
From: gabe@alteregotech.com
Subject: 📊 Weekly Summary: $HOST System Report

$MSG
REPORT

elif [ "$ALERT" -eq 1 ]; then
cat <<REPORT | msmtp -t
To: $ALERT_EMAIL
From: gabe@alteregotech.com
Subject: ⚠️ ALERT: $HOST - Resource usage warning

$MSG
REPORT

else
    echo "[$DATE] OK Disk/Memory/CPU normal" >> /var/log/server_health.log
fi
