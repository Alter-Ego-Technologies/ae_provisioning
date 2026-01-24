#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source /usr/local/sbin/ops-monitor-lib.sh

require_root
load_config

HOST="$(hostname_fqdn)"
NOW_HUMAN="$(date -Is)"
CHECK_INTERVAL_MIN="${CHECK_INTERVAL_MIN:-5}"

report_lines=()
changed_any=0

emit_change() {
  local key="$1" status="$2" msg="$3"
  local prev
  prev="$(state_get "status_${key}" 2>/dev/null || echo "")"

  if [[ "$prev" != "$status" ]]; then
    state_set "status_${key}" "$status"
    changed_any=1
    report_lines+=("[$status] $msg (prev: ${prev:-none})")
    mark_sent "$key"
  else
    if [[ "$status" != "OK" ]] && cooldown_ok "$key"; then
      changed_any=1
      report_lines+=("[$status] $msg (repeat)")
      mark_sent "$key"
    fi
  fi
}

disk_check() {
  local warn="${DISK_WARN:-80}" crit="${DISK_CRIT:-90}"
  while read -r fs type size used avail pct mount; do
    [[ "$type" =~ ^(tmpfs|devtmpfs|overlay|squashfs|proc|sysfs|cgroup2?)$ ]] && continue
    local p="${pct%\%}"
    local status="OK"
    if (( p >= crit )); then status="CRIT"
    elif (( p >= warn )); then status="WARN"
    fi
    emit_change "disk_${mount//\//_}" "$status" "Disk ${mount} at ${p}% (fs=${fs}, type=${type}, avail=${avail})"
  done < <(df -hT -P | awk 'NR>1{print $1,$2,$3,$4,$5,$6,$7}')
}

mem_check() {
  local warn="${MEM_WARN:-85}" crit="${MEM_CRIT:-95}"
  local mem_total mem_avail mem_used_pct
  mem_total="$(awk '/MemTotal:/{print $2}' /proc/meminfo)"
  mem_avail="$(awk '/MemAvailable:/{print $2}' /proc/meminfo)"
  [[ -z "${mem_total:-}" || -z "${mem_avail:-}" ]] && return 0
  mem_used_pct=$(( ( (mem_total - mem_avail) * 100 ) / mem_total ))
  local status="OK"
  if (( mem_used_pct >= crit )); then status="CRIT"
  elif (( mem_used_pct >= warn )); then status="WARN"
  fi
  emit_change "mem" "$status" "Memory used ${mem_used_pct}% (MemAvailable=$(awk "BEGIN{printf \"%.1f\", ${mem_avail}/1024/1024}")GiB)"
}

load_check() {
  local warn_per="${LOAD_WARN_PER_CORE:-1.5}" crit_per="${LOAD_CRIT_PER_CORE:-3.0}"
  local cores load1 warn crit
  cores="$(nproc 2>/dev/null || echo 1)"
  load1="$(awk '{print $1}' /proc/loadavg)"
  warn="$(awk -v p="$warn_per" -v c="$cores" 'BEGIN{printf "%.2f", p*c}')"
  crit="$(awk -v p="$crit_per" -v c="$cores" 'BEGIN{printf "%.2f", p*c}')"
  local status="OK"
  if awk -v l="$load1" -v t="$crit" 'BEGIN{exit !(l>=t)}'; then status="CRIT"
  elif awk -v l="$load1" -v t="$warn" 'BEGIN{exit !(l>=t)}'; then status="WARN"
  fi
  emit_change "load1" "$status" "Load1 ${load1} (cores=${cores}, warn>=${warn}, crit>=${crit})"
}

cpu_check() {
  local warn="${CPU_WARN:-90}" crit="${CPU_CRIT:-97}"
  local window_min="${CPU_WINDOW_MIN:-10}"
  local interval_min="${CHECK_INTERVAL_MIN:-5}"
  local samples_needed
  samples_needed=$(( (window_min + interval_min - 1) / interval_min ))
  (( samples_needed < 1 )) && samples_needed=1

  read -r cpu user nice sys idle iowait irq softirq steal guest guest_nice < <(awk '/^cpu /{print $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11}' /proc/stat)
  local total=$((user + nice + sys + idle + iowait + irq + softirq + steal))
  local idle_all=$((idle + iowait))

  local prev_total prev_idle
  prev_total="$(state_get cpu_prev_total 2>/dev/null || echo "")"
  prev_idle="$(state_get cpu_prev_idle 2>/dev/null || echo "")"

  state_set cpu_prev_total "$total"
  state_set cpu_prev_idle "$idle_all"

  [[ -z "${prev_total:-}" || -z "${prev_idle:-}" ]] && return 0

  local diff_total=$(( total - prev_total ))
  local diff_idle=$(( idle_all - prev_idle ))
  (( diff_total <= 0 )) && return 0

  local usage=$(( ( (diff_total - diff_idle) * 100 ) / diff_total ))

  local buf
  buf="$(state_get cpu_buf 2>/dev/null || echo "")"
  if [[ -z "$buf" ]]; then buf="$usage"; else buf="${buf},${usage}"; fi

  IFS=',' read -r -a arr <<< "$buf"
  if (( ${#arr[@]} > samples_needed )); then
    arr=( "${arr[@]: -$samples_needed}" )
  fi
  buf="$(IFS=','; echo "${arr[*]}")"
  state_set cpu_buf "$buf"

  local sum=0 v
  for v in "${arr[@]}"; do sum=$((sum + v)); done
  local avg=$(( sum / ${#arr[@]} ))

  local status="OK"
  if (( avg >= crit )); then status="CRIT"
  elif (( avg >= warn )); then status="WARN"
  fi
  emit_change "cpu" "$status" "CPU avg~${avg}% over ~${window_min}m (samples=${#arr[@]}: ${buf})"
}

services_check() {
  local svc
  for svc in ${SERVICES:-}; do
    [[ -z "$svc" ]] && continue
    local status="OK"
    if ! systemctl is-active --quiet "$svc"; then status="CRIT"; fi
    emit_change "svc_${svc}" "$status" "Service ${svc} is $(systemctl is-active "$svc" 2>/dev/null || echo unknown)"
  done
}

cert_check() {
  [[ -z "${CERT_PATHS:-}" ]] && return 0
  command -v openssl >/dev/null 2>&1 || return 0

  local warn_days="${CERT_WARN_DAYS:-14}" crit_days="${CERT_CRIT_DAYS:-7}"
  local path
  for path in ${CERT_PATHS}; do
    [[ -f "$path" ]] || continue
    local enddate end_epoch now days_left
    enddate="$(openssl x509 -enddate -noout -in "$path" 2>/dev/null | sed 's/^notAfter=//')"
    [[ -z "$enddate" ]] && continue
    end_epoch="$(date -d "$enddate" +%s 2>/dev/null || echo 0)"
    now="$(date +%s)"
    if (( end_epoch <= now )); then
      emit_change "cert_${path//\//_}" "CRIT" "Cert expired: ${path} (notAfter=${enddate})"
      continue
    fi
    days_left=$(( (end_epoch - now) / 86400 ))
    local status="OK"
    if (( days_left <= crit_days )); then status="CRIT"
    elif (( days_left <= warn_days )); then status="WARN"
    fi
    emit_change "cert_${path//\//_}" "$status" "Cert ${path} expires in ${days_left} days (notAfter=${enddate})"
  done
}

backup_check() {
  [[ -z "${BACKUP_OK_FILE:-}" ]] && return 0
  local file="${BACKUP_OK_FILE}"
  local warn_h="${BACKUP_WARN_HOURS:-24}" crit_h="${BACKUP_CRIT_HOURS:-48}"

  if [[ ! -e "$file" ]]; then
    emit_change "backup" "CRIT" "Backup heartbeat missing: ${file}"
    return 0
  fi

  local mtime now age_s age_h status="OK"
  mtime="$(stat -c %Y "$file" 2>/dev/null || echo 0)"
  now="$(date +%s)"
  age_s=$(( now - mtime ))
  age_h=$(( age_s / 3600 ))

  if (( age_h >= crit_h )); then status="CRIT"
  elif (( age_h >= warn_h )); then status="WARN"
  fi
  emit_change "backup" "$status" "Backup heartbeat age ${age_h}h (file=${file})"
}

postfix_queue_counts() {
  if ! command -v postqueue >/dev/null 2>&1; then
    echo "0 0"; return
  fi
  local out total deferred
  out="$(postqueue -p 2>/dev/null || true)"
  if echo "$out" | grep -q "Mail queue is empty"; then
    echo "0 0"; return
  fi
  total="$(echo "$out" | tail -n1 | awk '{for(i=1;i<=NF;i++) if($i=="in") {print $(i+2)} }' | tr -d '.' )"
  total="${total:-0}"
  deferred="$(echo "$out" | grep -ci "deferred" || true)"
  echo "$total $deferred"
}

mail_check() {
  [[ "${ROLE:-base}" != "mail" ]] && return 0
  local qw="${MAIL_QUEUE_WARN:-200}" qc="${MAIL_QUEUE_CRIT:-500}"
  local dw="${MAIL_DEFERRED_WARN:-50}" dc="${MAIL_DEFERRED_CRIT:-150}"
  read -r total deferred < <(postfix_queue_counts)

  local status_q="OK"
  if (( total >= qc )); then status_q="CRIT"
  elif (( total >= qw )); then status_q="WARN"
  fi
  emit_change "mail_queue" "$status_q" "Postfix queue total=${total} (warn>=${qw}, crit>=${qc})"

  local status_d="OK"
  if (( deferred >= dc )); then status_d="CRIT"
  elif (( deferred >= dw )); then status_d="WARN"
  fi
  emit_change "mail_deferred" "$status_d" "Postfix deferred=${deferred} (warn>=${dw}, crit>=${dc})"
}

disk_check
mem_check
load_check
cpu_check
services_check
cert_check
backup_check
mail_check

if (( changed_any == 1 )); then
  max="OK"
  for line in "${report_lines[@]}"; do
    sev="$(awk '{gsub(/\[/,""); gsub(/\]/,""); print $1}' <<<"$line")"
    if (( $(status_rank "$sev") > $(status_rank "$max") )); then max="$sev"; fi
  done

  subject="ALERT [${max}] ${HOST} (${ROLE})"
  body="$(cat <<EOF
Host: ${HOST}
Role: ${ROLE}
Time: ${NOW_HUMAN}

Items:
$(printf '%s\n' "${report_lines[@]}")

State: ${STATE_DIR}/state.env
EOF
)"
  send_email "$subject" "$body"
fi
