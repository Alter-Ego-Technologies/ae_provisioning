#!/bin/bash

# === CONFIG ===
domains=(
  mail.clearpointreporting.com
  imap.clearpointreporting.com
  smtp.clearpointreporting.com
  webmail.clearpointreporting.com
  autoconfig.clearpointreporting.com
  autodiscover.clearpointreporting.com
  www.clearpointreporting.com
  clearpointreport.com

  mail.gabriellindsey.com
  imap.gabriellindsey.com
  smtp.gabriellindsey.com
  webmail.gabriellindsey.com
  autoconfig.gabriellindsey.com
  autodiscover.gabriellindsey.com

  mail.koditalk.email
  imap.koditalk.email
  smtp.koditalk.email
  webmail.koditalk.email
  autoconfig.koditalk.email
  autodiscover.koditalk.email

  mail.koditalk.tv
  imap.koditalk.tv
  smtp.koditalk.tv
  webmail.koditalk.tv
  autoconfig.koditalk.tv
  autodiscover.koditalk.tv

  mail.alteregotech.com
  imap.alteregotech.com
  smtp.alteregotech.com
  webmail.alteregotech.com
  autoconfig.alteregotech.com
  autodiscover.alteregotech.com
)

LOG_FILE="/var/log/domain-warmup.log"
WEBHOOK_URL="" # optional: Discord/Slack/Teams/etc.
EMAIL_ALERT=""  # optional: email@example.com

# === LOGGING ===
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# === MAIN ===
log "🔄 Starting domain warmup..."

for domain in "${domains[@]}"; do
  status=$(curl -s -o /dev/null -w "%{http_code}" --head --max-time 10 https://$domain)
  
  if [[ "$status" =~ ^2|3 ]]; then
    log "✅ $domain is up (HTTP $status)"
  else
    log "❌ $domain failed (HTTP $status)"

    # Optional email
    if [[ -n "$EMAIL_ALERT" ]]; then
      echo "$domain returned HTTP $status at $(date)" | mail -s "⚠️ Warmup Check Failed: $domain" "$EMAIL_ALERT"
    fi

    # Optional webhook
    if [[ -n "$WEBHOOK_URL" ]]; then
      curl -s -X POST -H "Content-Type: application/json" \
        -d "{\"text\":\"❌ $domain failed warmup check (HTTP $status)\"}" "$WEBHOOK_URL" > /dev/null
    fi
  fi
done

log "✅ Warmup complete."
