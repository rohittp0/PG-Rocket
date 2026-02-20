#!/usr/bin/env bash
set -euo pipefail

# -------------------------
# Required env
# -------------------------
: "${STACK_NAME}"

: "${POSTGRES_DB:?}"
: "${POSTGRES_USER:?}"
: "${POSTGRES_PASSWORD:?}"

: "${SPACES_ENDPOINT:?}"   # nyc3.digitaloceanspaces.com
: "${SPACES_BUCKET:?}"     # b-space
: "${SPACES_KEY:?}"
: "${SPACES_SECRET:?}"

: "${TELEGRAM_BOT_TOKEN:?}"
: "${TELEGRAM_CHAT_ID:?}"

# -------------------------
# Scheduling / retries
# -------------------------
: "${BACKUP_EVERY_DAYS:=1}"
: "${CHECK_EVERY_MINUTES:=10}"
: "${JITTER_MAX_SECONDS:=900}"
: "${MAX_RETRIES:=5}"
: "${RETRY_SLEEP_SECONDS:=60}"

STATE_DIR="/state"
LOCK_FILE="${STATE_DIR}/backup.lock"
LAST_OK_FILE="${STATE_DIR}/last_success_epoch"
LOG_DIR="${STATE_DIR}/logs"
mkdir -p "${STATE_DIR}" "${LOG_DIR}"

now_epoch() { date +%s; }

tg_send() {
  local text="$1"
  # Use data-urlencode to avoid escaping issues
  curl -fsS "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${text}" \
    >/dev/null || true
}

should_run() {
  if [[ ! -f "${LAST_OK_FILE}" ]]; then
    return 0
  fi
  local last
  last="$(cat "${LAST_OK_FILE}" 2>/dev/null || echo 0)"
  local age=$(( $(now_epoch) - last ))
  local threshold=$(( BACKUP_EVERY_DAYS * 86400 ))
  [[ "${age}" -ge "${threshold}" ]]
}

run_with_retries() {
  local n=0
  until "$@"; do
    n=$((n+1))
    if [[ "${n}" -ge "${MAX_RETRIES}" ]]; then
      return 1
    fi
    sleep "${RETRY_SLEEP_SECONDS}"
  done
}

write_pgpass() {
  # libpq allows unix socket directory in host field in .pgpass
  local pgpass="${STATE_DIR}/.pgpass"
  umask 077
  printf "%s:%s:%s:%s:%s\n" "/var/run/postgresql" "5432" "${POSTGRES_DB}" "${POSTGRES_USER}" "${POSTGRES_PASSWORD}" > "${pgpass}"
}

write_pgbackrest_conf() {
  # pg1-path must match where Postgres keeps PGDATA.
  # Your volume mount is /var/lib/postgresql; official images typically use /var/lib/postgresql/data.
  local pgdata="/var/lib/postgresql/data"
  if [[ ! -d "${pgdata}" ]]; then
    # fallback (some setups put PGDATA directly under the mount)
    pgdata="/var/lib/postgresql"
  fi

  cat > /etc/pgbackrest/pgbackrest.conf <<EOF
[global]
# logs inside /state (persist across restarts)
log-level-console=info
log-level-file=detail
log-path=${LOG_DIR}

# S3/Spaces repo
repo1-type=s3
repo1-s3-endpoint=${SPACES_ENDPOINT}
repo1-s3-bucket=${SPACES_BUCKET}
repo1-s3-key=${SPACES_KEY}
repo1-s3-key-secret=${SPACES_SECRET}
repo1-s3-region=us-east-1
repo1-s3-uri-style=path

# prefix backups by stack
repo1-path=/${STACK_NAME}

# retain at most Y full backups
repo1-retention-full=${BACKUP_RETAIN_COUNT}
repo1-retention-full-type=count

# optional: compress repo data
compress-type=zst

[main]
pg1-path=${pgdata}
pg1-socket-path=/var/run/postgresql
pg1-user=${POSTGRES_USER}
pg1-database=${POSTGRES_DB}
EOF
}

ensure_stanza() {
  # If stanza isn't created yet, create it.
  # We’ll try info; if it fails, run stanza-create.
  if ! pgbackrest --stanza="main" info >/dev/null 2>&1; then
    pgbackrest --stanza="main" stanza-create
  fi
}

latest_backup_stats() {
  # Return a short human-friendly line about the latest backup
  # Uses pgbackrest info --output=json and jq
  pgbackrest --stanza="main" info --output=json \
    | jq -r '
      .[0].backup[-1] as $b |
      if $b == null then
        "No backups found in repo."
      else
        "latest=\($b.label) type=\($b.type) start=\($b.timestamp.start) stop=\($b.timestamp.stop) size=\($b.info.size)B delta=\($b.info.delta)B"
      end
    ' 2>/dev/null || echo "Stats unavailable."
}

do_backup() {
  exec 9>"${LOCK_FILE}"
  if ! flock -n 9; then
    return 0
  fi

  local start_iso start_epoch end_epoch duration
  start_iso="$(date -Is)"
  start_epoch="$(now_epoch)"

  # Run FULL backups so retention count means “versions”
  local out_file="${LOG_DIR}/backup_$(date +%F_%H%M%S).log"

  set +e
  pgbackrest --stanza="main" backup --type=full >"${out_file}" 2>&1
  local rc=$?
  set -e

  end_epoch="$(now_epoch)"
  duration=$(( end_epoch - start_epoch ))

  if [[ "${rc}" -eq 0 ]]; then
    echo "${end_epoch}" > "${LAST_OK_FILE}"
    local stats
    stats="$(latest_backup_stats)"
    tg_send "✅ Backup SUCCESS
stack=${STACK_NAME}
started=${start_iso}
duration=${duration}s
${stats}"
    return 0
  else
    # Include the tail of the log as the “reason”
    local reason
    reason="$(tail -n 25 "${out_file}" | sed 's/\r$//' | head -c 3500)"
    tg_send "❌ Backup FAILED
stack=${STACK_NAME}
started=${start_iso}
duration=${duration}s
reason:
${reason}"
    return "${rc}"
  fi
}

# Initial jitter so all nodes don’t hit Spaces at once
sleep $(( RANDOM % (JITTER_MAX_SECONDS + 1) ))

write_pgpass
export PGPASSFILE="${STATE_DIR}/.pgpass"
write_pgbackrest_conf
ensure_stanza

# Main loop (catch-up scheduler)
while true; do
  if should_run; then
    run_with_retries do_backup || true
  fi
  sleep $(( CHECK_EVERY_MINUTES * 60 ))
done
