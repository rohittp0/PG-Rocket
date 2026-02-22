#!/usr/bin/env bash
set -euo pipefail

# =========================================================================
# pg-rocket-entrypoint.sh — wrapper around the official postgres entrypoint
# Runs as root, sets up pgbackrest + cron, then hands off to postgres.
# If ENABLE_DB_BACKUP != "true", skips all backup setup and acts as plain postgis.
# =========================================================================

: "${POSTGRES_DB:?POSTGRES_DB is required}"
: "${POSTGRES_USER:?POSTGRES_USER is required}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}"
: "${PGDATA:?PGDATA is required}"

PGDATA_PARENT="$(dirname "${PGDATA}")"
PGDATA_ROOT="$(dirname "${PGDATA_PARENT}")"

permission_fix_hint() {
  cat <<EOF
chown -R postgres:postgres "${PGDATA_PARENT}" && chmod 755 "${PGDATA_ROOT}" && chmod 700 "${PGDATA_PARENT}" "${PGDATA}"
EOF
}

fail_pgdata_permission() {
  local path="$1"
  local reason="$2"
  cat >&2 <<EOF
ERROR: PGDATA startup preflight failed.
Path: ${path}
Required user: postgres
Failure: ${reason}
Suggested fix:
  $(permission_fix_hint)
EOF
  exit 1
}

normalize_pgdata_permissions() {
  if [ "$(id -u)" -ne 0 ]; then
    fail_pgdata_permission "${PGDATA}" "entrypoint must run as root to normalize PGDATA ownership and permissions."
  fi

  mkdir -p "${PGDATA_PARENT}" "${PGDATA}" \
    || fail_pgdata_permission "${PGDATA}" "unable to create PGDATA directories."
  chown -R postgres:postgres "${PGDATA_PARENT}" \
    || fail_pgdata_permission "${PGDATA_PARENT}" "unable to set ownership to postgres:postgres."
  chmod 755 "${PGDATA_ROOT}" \
    || fail_pgdata_permission "${PGDATA_ROOT}" "unable to set mode 755."
  chmod 700 "${PGDATA_PARENT}" "${PGDATA}" \
    || fail_pgdata_permission "${PGDATA}" "unable to set mode 700 on PGDATA path."
}

assert_postgres_pgdata_access() {
  gosu postgres test -x "${PGDATA_ROOT}" \
    || fail_pgdata_permission "${PGDATA_ROOT}" "postgres cannot traverse this directory."
  gosu postgres test -x "${PGDATA_PARENT}" \
    || fail_pgdata_permission "${PGDATA_PARENT}" "postgres cannot traverse this directory."
  gosu postgres test -x "${PGDATA}" \
    || fail_pgdata_permission "${PGDATA}" "postgres cannot traverse this directory."

  if [ -e "${PGDATA}/PG_VERSION" ]; then
    gosu postgres test -r "${PGDATA}/PG_VERSION" \
      || fail_pgdata_permission "${PGDATA}/PG_VERSION" "postgres cannot read PG_VERSION."
  fi
}

if [ "${ENABLE_DB_BACKUP:-}" = "true" ]; then

# -------------------------
# 1. Validate backup-related env vars
# -------------------------
: "${STACK_NAME:?STACK_NAME is required}"
: "${S3_ENDPOINT:?S3_ENDPOINT is required}"
: "${S3_BUCKET:?S3_BUCKET is required}"
: "${S3_KEY:?S3_KEY is required}"
: "${S3_SECRET:?S3_SECRET is required}"
: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN is required}"
: "${TELEGRAM_CHAT_ID:?TELEGRAM_CHAT_ID is required}"

# -------------------------
# 2. Defaults for optional vars
# -------------------------
: "${S3_REGION:=us-east-1}"
: "${BACKUP_CRON:=0 3 * * 2}"
: "${BACKUP_RETAIN_COUNT:=1}"
: "${MAX_RETRIES:=5}"
: "${RETRY_SLEEP_SECONDS:=60}"
: "${PRIMARY_READY_TIMEOUT_SECONDS:=300}"
: "${PGBACKREST_LOCK_PATH:=/tmp/pgbackrest}"

export S3_REGION BACKUP_CRON BACKUP_RETAIN_COUNT MAX_RETRIES RETRY_SLEEP_SECONDS PGBACKREST_LOCK_PATH

LOG_DIR="/var/log/pgbackrest"
mkdir -p "${LOG_DIR}" /etc/pgbackrest "${PGBACKREST_LOCK_PATH}"
chown -R postgres:postgres "${LOG_DIR}" "${PGBACKREST_LOCK_PATH}"

# -------------------------
# 3. Write pgbackrest.conf
# -------------------------
cat > /etc/pgbackrest/pgbackrest.conf <<EOF
[global]
log-level-console=info
log-level-file=detail
log-path=${LOG_DIR}

repo1-type=s3
repo1-s3-endpoint=${S3_ENDPOINT}
repo1-s3-bucket=${S3_BUCKET}
repo1-s3-key=${S3_KEY}
repo1-s3-key-secret=${S3_SECRET}
repo1-s3-region=${S3_REGION}
repo1-s3-uri-style=path

repo1-path=/pg/${STACK_NAME}/${POSTGRES_DB}

repo1-retention-full=${BACKUP_RETAIN_COUNT}

compress-type=zst
process-max=4
lock-path=${PGBACKREST_LOCK_PATH}

[main]
pg1-path=${PGDATA}
pg1-socket-path=/var/run/postgresql
pg1-user=${POSTGRES_USER}
pg1-database=${POSTGRES_DB}
EOF

# -------------------------
# 4. Init script for WAL archiving (runs only on fresh DB init)
# -------------------------
mkdir -p /docker-entrypoint-initdb.d
cat > /docker-entrypoint-initdb.d/00-pgbackrest-archiving.sh <<'INITEOF'
#!/bin/bash
echo "pg-rocket: enabling WAL archiving..."
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-SQL
    ALTER SYSTEM SET archive_mode = on;
    ALTER SYSTEM SET archive_command = 'pgbackrest --stanza=main archive-push %p';
SQL
echo "pg-rocket: WAL archiving configured (takes effect after restart)."
INITEOF
chmod +x /docker-entrypoint-initdb.d/00-pgbackrest-archiving.sh

# -------------------------
# 5. Write env file for cron
# -------------------------
ENV_FILE="/etc/pg-rocket-env.sh"
cat > "${ENV_FILE}" <<EOF
export STACK_NAME="${STACK_NAME}"
export POSTGRES_DB="${POSTGRES_DB}"
export POSTGRES_USER="${POSTGRES_USER}"
export POSTGRES_PASSWORD="${POSTGRES_PASSWORD}"
export S3_ENDPOINT="${S3_ENDPOINT}"
export S3_BUCKET="${S3_BUCKET}"
export S3_KEY="${S3_KEY}"
export S3_SECRET="${S3_SECRET}"
export S3_REGION="${S3_REGION}"
export TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}"
export TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID}"
export BACKUP_RETAIN_COUNT="${BACKUP_RETAIN_COUNT}"
export MAX_RETRIES="${MAX_RETRIES}"
export RETRY_SLEEP_SECONDS="${RETRY_SLEEP_SECONDS}"
export PGDATA="${PGDATA}"
EOF
chmod 600 "${ENV_FILE}"

# -------------------------
# 6. Install cron job
# -------------------------
cat > /etc/cron.d/pg-rocket-backup <<EOF
${BACKUP_CRON} root /usr/local/bin/backup.sh >> ${LOG_DIR}/cron.log 2>&1
EOF
chmod 644 /etc/cron.d/pg-rocket-backup

# -------------------------
# 7. Start cron daemon
# -------------------------
cron

# -------------------------
# 8. PGDATA check (wait for restore if needed)
# -------------------------
if [ ! -s "${PGDATA}/PG_VERSION" ]; then
  if [ -z "${PG_AUTO_INIT:-}" ]; then
    echo "pg-rocket: PGDATA is empty and PG_AUTO_INIT is not set."
    echo "pg-rocket: Waiting for manual restore... (run: docker exec -it <container> restore.sh)"
    while [ ! -s "${PGDATA}/PG_VERSION" ]; do
      sleep 10
    done
    echo "pg-rocket: PG_VERSION detected, starting postgres..."
  fi
fi

# -------------------------
# 9. Post-start background task
# -------------------------
(
  until pg_isready -q -h /var/run/postgresql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}"; do
    sleep 2
  done
  sleep 3

  # During restore startup the cluster can be up but still in recovery.
  # Wait for read-write primary mode before running stanza/create backup setup.
  waited=0
  while true; do
    recovery_state="$(psql -h /var/run/postgresql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -tAc "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d '[:space:]' || echo "t")"
    if [ "${recovery_state}" = "f" ]; then
      break
    fi

    if [ "${waited}" -ge "${PRIMARY_READY_TIMEOUT_SECONDS}" ]; then
      echo "pg-rocket: timed out waiting for primary mode after ${PRIMARY_READY_TIMEOUT_SECONDS}s; skipping post-start stanza/backup setup."
      exit 0
    fi

    sleep 2
    waited=$((waited + 2))
  done

  # Check archive_mode
  archive_mode="$(psql -h /var/run/postgresql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -tAc "SHOW archive_mode;" 2>/dev/null || echo "off")"
  if [ "${archive_mode}" != "on" ]; then
    psql -h /var/run/postgresql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -tAc "ALTER SYSTEM SET archive_mode = on;" 2>/dev/null || true
    psql -h /var/run/postgresql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -tAc "ALTER SYSTEM SET archive_command = 'pgbackrest --stanza=main archive-push %p';" 2>/dev/null || true

    curl -fsS "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
      --data-urlencode "text=⚠️ pg-rocket: archive_mode is not enabled. A restart is needed.
stack=${STACK_NAME}
Run: docker compose restart" \
      >/dev/null 2>&1 || true
  fi

  # Create/verify stanza
  if ! gosu postgres pgbackrest --stanza=main stanza-create 2>/dev/null; then
    gosu postgres pgbackrest --stanza=main stanza-delete --force 2>/dev/null || true
    gosu postgres pgbackrest --stanza=main stanza-create 2>/dev/null || true
  fi

  # If no full backup exists yet, run one now
  full_count="$(gosu postgres pgbackrest --stanza=main info --output=json \
    | jq '[.[0].backup[] | select(.type == "full")] | length' 2>/dev/null || echo 0)"
  if [ "${full_count}" -eq 0 ]; then
    echo "pg-rocket: no full backup found, running initial backup..."
    /usr/local/bin/backup.sh || true
  fi

  echo "pg-rocket: post-start setup complete."
) &

fi # end ENABLE_DB_BACKUP

# -------------------------
# 10. Hand off to official postgres entrypoint
# -------------------------
normalize_pgdata_permissions
assert_postgres_pgdata_access
exec docker-entrypoint.sh "$@"
