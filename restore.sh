#!/usr/bin/env bash
set -euo pipefail

# =========================================================================
# restore.sh — interactive restore from pgbackrest S3 repository
# Run inside the container: docker exec -it <container> restore.sh
# =========================================================================

# Source environment if available (written by pg-rocket-entrypoint.sh)
if [ -f /etc/pg-rocket-env.sh ]; then
  source /etc/pg-rocket-env.sh
fi

LOG_DIR="/var/log/pgbackrest"
mkdir -p "${LOG_DIR}"

: "${PGDATA:?PGDATA is not set}"

# -------------------------
# Fetch and display backups
# -------------------------
echo ""
echo "Fetching available backups..."
echo ""

backup_json="$(pgbackrest --stanza=main info --output=json)"

backup_count="$(echo "${backup_json}" | jq '.[0].backup | length')"

if [ "${backup_count}" -eq 0 ]; then
  echo "No backups found in repository."
  exit 1
fi

echo "${backup_json}" | jq -r '
  def hbytes($n):
    if ($n // 0) < 1024 then "\($n // 0) B"
    elif ($n // 0) < 1048576 then "\(((($n / 1024) * 10) | floor) / 10) KiB"
    elif ($n // 0) < 1073741824 then "\(((($n / 1048576) * 10) | floor) / 10) MiB"
    else "\(((($n / 1073741824) * 100) | floor) / 100) GiB"
    end;
  .[0].backup | to_entries[] |
  "  [\(.key + 1)] \(.value.label)  \(.value.type | ascii_upcase)  \(.value.timestamp.start | strftime("%Y-%m-%d %H:%M UTC"))  size=\(hbytes(.value.info.size))  delta=\(hbytes(.value.info.delta))"
'

echo ""
echo "  [0] Cancel"
echo ""

# -------------------------
# Selection
# -------------------------
read -rp "Select backup to restore [0-${backup_count}]: " choice

if [ "${choice}" = "0" ] || [ -z "${choice}" ]; then
  echo "Cancelled."
  exit 0
fi

if ! [[ "${choice}" =~ ^[0-9]+$ ]] || [ "${choice}" -lt 1 ] || [ "${choice}" -gt "${backup_count}" ]; then
  echo "Invalid selection."
  exit 1
fi

idx=$((choice - 1))
backup_label="$(echo "${backup_json}" | jq -r ".[0].backup[${idx}].label")"
backup_type="$(echo "${backup_json}" | jq -r ".[0].backup[${idx}].type | ascii_upcase")"
backup_time="$(echo "${backup_json}" | jq -r ".[0].backup[${idx}].timestamp.start | strftime(\"%Y-%m-%d %H:%M UTC\")")"

echo ""
echo "Selected: ${backup_label} (${backup_type}, ${backup_time})"
echo ""

# -------------------------
# Safety checks
# -------------------------
# Check postgres is not running
if [ -S /var/run/postgresql/.s.PGSQL.5432 ]; then
  echo "ERROR: PostgreSQL appears to be running."
  echo "Stop the container first, then restart without PG_AUTO_INIT."
  exit 1
fi

# Check pgdata is writable
if [ -d "${PGDATA}" ]; then
  if ! touch "${PGDATA}/.restore_test" 2>/dev/null; then
    echo "ERROR: PGDATA directory is not writable."
    exit 1
  fi
  rm -f "${PGDATA}/.restore_test"
fi

# -------------------------
# Confirm
# -------------------------
echo "WARNING: This will REPLACE all data in ${PGDATA}."
read -rp "Type 'yes' to confirm restore: " confirm

if [ "${confirm}" != "yes" ]; then
  echo "Cancelled."
  exit 0
fi

# -------------------------
# Restore
# -------------------------
echo ""
echo "Restoring backup ${backup_label}..."
echo ""

restore_log="${LOG_DIR}/restore_$(date +%F_%H%M%S).log"

pgbackrest --stanza=main restore --set="${backup_label}" --delta --link-all \
  >"${restore_log}" 2>&1 &
restore_pid=$!

# Show last log line as a live progress indicator
while kill -0 "${restore_pid}" 2>/dev/null; do
  last_line="$(tail -1 "${restore_log}" 2>/dev/null || true)"
  if [ -n "${last_line}" ]; then
    printf "\r\033[K%s" "${last_line}"
  fi
  sleep 1
done

set +e
wait "${restore_pid}"
rc=$?
set -e

printf "\r\033[K"
echo ""

if [ "${rc}" -eq 0 ]; then
  echo "Fixing ownership..."
  chown -R postgres:postgres "${PGDATA}"
  echo ""
  echo "Restore completed successfully."
  echo "The entrypoint will detect PG_VERSION and start postgres automatically."
else
  echo "Restore FAILED (exit code ${rc}). Check log: ${restore_log}"
fi

echo ""
exit "${rc}"
