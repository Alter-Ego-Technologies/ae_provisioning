#!/bin/bash

# ============ SETTINGS ============
TO="gabe@alteregotech.com webmaster@clearpointreporting.com"        # Change to your destination email
SUBJECT="Mailcow Health Report - $(hostname) - $(date '+%Y-%m-%d %H:%M')"
TMPFILE=$(mktemp /tmp/healthreport.XXXXXX)

# ============ GENERATE REPORT ============
{
echo "====================================================="
echo "        MAILCOW SERVER HEALTH REPORT"
echo "====================================================="
echo ""
echo "Hostname: $(hostname)"
echo "Date: $(date)"
echo ""

echo "====================================================="
echo "🐳 Docker Storage (docker system df)"
echo "====================================================="
docker system df
echo ""

echo "====================================================="
echo "📁 Docker Volumes (size summary)"
echo "====================================================="
for vol in $(docker volume ls -q); do
    size=$(docker run --rm -v "$vol":/v alpine sh -c "du -sh /v 2>/dev/null | cut -f1")
    printf "%-40s %10s\n" "$vol" "$size"
done
echo ""

echo "====================================================="
echo "📬 Mail Volume Usage (/mnt/Mail)"
echo "====================================================="
du -sh /mnt/Mail 2>/dev/null
echo ""

echo "====================================================="
echo "📧 Mailbox Sizes (per-domain summary)"
echo "====================================================="
find /mnt/Mail -maxdepth 2 -type d -exec du -sh {} \; 2>/dev/null | sort -h | tail -20
echo ""

echo "====================================================="
echo "🔥 Docker Containers Running"
echo "====================================================="
docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"
echo ""

echo "====================================================="
echo "✔ Health Report Completed"
echo "====================================================="
} > "$TMPFILE"

# ============ SEND EMAIL ============
mail -s "$SUBJECT" "$TO" < "$TMPFILE"

rm -f "$TMPFILE"
