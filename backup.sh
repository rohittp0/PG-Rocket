#!/usr/bin/env bash
set -euo pipefail

# =========================================================================
# backup.sh — called by cron, runs a full pgbackrest backup with retries
# =========================================================================

# Source environment (written by pg-rocket-entrypoint.sh)
source /etc/pg-rocket-env.sh

LOCK_FILE="/tmp/pg-rocket-backup.lock"
LOG_DIR="/var/log/pgbackrest"
mkdir -p "${LOG_DIR}"

# -------------------------
# Helpers
# -------------------------
tg_send() {
  local text="$1"
  curl -fsS "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${text}" \
    >/dev/null || true
}

format_duration() {
  local seconds="${1:-0}"
  if (( seconds < 60 )); then
    printf "%ss" "${seconds}"
  elif (( seconds < 3600 )); then
    printf "%sm %ss" "$((seconds / 60))" "$((seconds % 60))"
  else
    printf "%sh %sm %ss" "$((seconds / 3600))" "$(((seconds % 3600) / 60))" "$((seconds % 60))"
  fi
}

latest_backup_stats() {
  pgbackrest --stanza="main" info --output=json \
    | jq -r '
      def hbytes($n):
        if ($n // 0) < 1024 then "\(($n // 0) | floor) B"
        elif ($n // 0) < 1048576 then "\((($n / 1024) * 10 | floor) / 10) KiB"
        elif ($n // 0) < 1073741824 then "\((($n / 1048576) * 10 | floor) / 10) MiB"
        else "\((($n / 1073741824) * 10 | floor) / 10) GiB"
        end;
      def hduration($s):
        if ($s // 0) < 60 then "\(($s // 0) | floor)s"
        elif ($s // 0) < 3600 then "\((($s // 0) / 60 | floor))m \((($s // 0) % 60))s"
        else "\((($s // 0) / 3600 | floor))h \((((($s // 0) % 3600) / 60) | floor))m \((($s // 0) % 60))s"
        end;
      .[0].backup[-1] as $b |
      if $b == null then
        "Latest backup: none found in repository."
      else
        (($b.timestamp.stop // 0) - ($b.timestamp.start // 0)) as $runtime |
        "Latest backup details:\n" +
        "- Label: \($b.label)\n" +
        "- Type: \($b.type | ascii_upcase)\n" +
        "- Started: \($b.timestamp.start | strftime("%Y-%m-%d %H:%M:%S UTC"))\n" +
        "- Finished: \($b.timestamp.stop | strftime("%Y-%m-%d %H:%M:%S UTC"))\n" +
        "- Runtime: \(hduration($runtime))\n" +
        "- Size: \(hbytes($b.info.size))\n" +
        "- Delta: \(hbytes($b.info.delta))"
      end
    ' 2>/dev/null || echo "Latest backup details unavailable."
}

# -------------------------
# Acquire lock (skip if already running)
# -------------------------
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  echo "backup.sh: another backup is already running, skipping."
  exit 0
fi

# -------------------------
# Run backup with retries
# -------------------------
start_iso="$(date -Is)"
start_epoch="$(date +%s)"

out_file="${LOG_DIR}/backup_$(date +%F_%H%M%S).log"

attempt=0
rc=1
while [ "${attempt}" -lt "${MAX_RETRIES}" ]; do
  attempt=$((attempt + 1))

  set +e
  gosu postgres pgbackrest --stanza=main backup --type=full >"${out_file}" 2>&1
  rc=$?
  set -e

  if [ "${rc}" -eq 0 ]; then
    break
  fi

  echo "backup.sh: attempt ${attempt}/${MAX_RETRIES} failed (exit ${rc})" >&2
  if [ "${attempt}" -lt "${MAX_RETRIES}" ]; then
    sleep "${RETRY_SLEEP_SECONDS}"
  fi
done

end_epoch="$(date +%s)"
duration=$(( end_epoch - start_epoch ))
duration_human="$(format_duration "${duration}")"

if [ "${rc}" -eq 0 ]; then
  stats="$(latest_backup_stats)"
  tg_send "✅ Backup completed successfully
Stack: ${STACK_NAME}
Type: FULL
Started: ${start_iso}
Duration: ${duration_human}

${stats}"
else
  reason="$(tail -n 25 "${out_file}" | head -c 3500)"
  tg_send "❌ Backup failed
Stack: ${STACK_NAME}
Type: FULL
Started: ${start_iso}
Duration: ${duration_human}
Attempts: ${attempt}/${MAX_RETRIES}
Error log (last 25 lines):
${reason}"
fi

exit "${rc}"
