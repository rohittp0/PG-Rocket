#!/usr/bin/env bash
set -euo pipefail

# =========================================================================
# setup-pgbackrest.sh — generate pgbackrest.conf and required directories
# Extracted from pg-rocket-entrypoint.sh so restore.sh can also call it.
# Idempotent — safe to call multiple times.
# =========================================================================

: "${STACK_NAME:?STACK_NAME is required}"
: "${S3_ENDPOINT:?S3_ENDPOINT is required}"
: "${S3_BUCKET:?S3_BUCKET is required}"
: "${S3_KEY:?S3_KEY is required}"
: "${S3_SECRET:?S3_SECRET is required}"

: "${POSTGRES_DB:?POSTGRES_DB is required}"
: "${POSTGRES_USER:?POSTGRES_USER is required}"
: "${PGDATA:?PGDATA is required}"

: "${S3_REGION:=us-east-1}"
: "${BACKUP_RETENTION_DAYS:=90}"
: "${PGBACKREST_LOCK_PATH:=/tmp/pgbackrest}"

export S3_REGION BACKUP_RETENTION_DAYS PGBACKREST_LOCK_PATH

# BACKUP_RETAIN_COUNT counted backup sets; BACKUP_RETENTION_DAYS counts days.
# Same numbers, different units — reading a stale "1" as the retention value
# would silently produce a one-day recovery window, so the old variable is
# deliberately inert rather than reinterpreted. See docs/adr/0001.
if [ -n "${BACKUP_RETAIN_COUNT:-}" ]; then
  cat >&2 <<EOF
setup-pgbackrest: WARNING: BACKUP_RETAIN_COUNT=${BACKUP_RETAIN_COUNT} is set and is IGNORED.
  It has been replaced by BACKUP_RETENTION_DAYS (currently ${BACKUP_RETENTION_DAYS}), which is
  measured in days rather than backup sets. Remove BACKUP_RETAIN_COUNT from this stack's .env.
EOF
fi

if ! [[ "${BACKUP_RETENTION_DAYS}" =~ ^[0-9]+$ ]] || [ "${BACKUP_RETENTION_DAYS}" -lt 1 ]; then
  echo "setup-pgbackrest: ERROR: BACKUP_RETENTION_DAYS must be a positive integer (got '${BACKUP_RETENTION_DAYS}')." >&2
  exit 1
fi

# Wasabi bills deleted objects to day 90 regardless, so a shorter window discards
# recovery points that have already been paid for.
if [ "${BACKUP_RETENTION_DAYS}" -lt 90 ]; then
  echo "setup-pgbackrest: WARNING: BACKUP_RETENTION_DAYS=${BACKUP_RETENTION_DAYS} is below the 90-day minimum storage duration; shortening it saves nothing." >&2
fi

LOG_DIR="/var/log/pgbackrest"
mkdir -p "${LOG_DIR}" /etc/pgbackrest "${PGBACKREST_LOCK_PATH}"
chown -R postgres:postgres "${LOG_DIR}" "${PGBACKREST_LOCK_PATH}"

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

# Time-based retention keeps every full backup inside the window, plus the newest
# full that predates it (needed to recover to the window's start). It also makes
# repo1-retention-archive default to retaining WAL back to the oldest retained
# full, which is what makes point-in-time recovery across the whole window work.
# Under count-based retention only one backup set's worth of WAL was kept.
repo1-retention-full-type=time
repo1-retention-full=${BACKUP_RETENTION_DAYS}

compress-type=zst
process-max=4
lock-path=${PGBACKREST_LOCK_PATH}

[main]
pg1-path=${PGDATA}
pg1-socket-path=/var/run/postgresql
pg1-user=${POSTGRES_USER}
pg1-database=${POSTGRES_DB}
EOF

echo "setup-pgbackrest: config written to /etc/pgbackrest/pgbackrest.conf"
