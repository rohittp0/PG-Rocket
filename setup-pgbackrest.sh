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
: "${BACKUP_RETAIN_COUNT:=1}"
: "${PGBACKREST_LOCK_PATH:=/tmp/pgbackrest}"

export S3_REGION BACKUP_RETAIN_COUNT PGBACKREST_LOCK_PATH

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

echo "setup-pgbackrest: config written to /etc/pgbackrest/pgbackrest.conf"
