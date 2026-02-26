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

# Auto-generate pgbackrest config if missing (e.g. staging with no backup enabled)
if [ ! -f /etc/pgbackrest/pgbackrest.conf ]; then
  echo "pgbackrest config not found, generating..."
  /usr/local/bin/setup-pgbackrest.sh
fi

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
ERROR: PGDATA permission check failed.
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
    fail_pgdata_permission "${PGDATA}" "restore.sh must run as root to normalize PGDATA ownership and permissions."
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

backup_auth_config() {
  SAVED_PG_HBA=""
  SAVED_PG_IDENT=""

  if [ -f "${PGDATA}/pg_hba.conf" ]; then
    SAVED_PG_HBA="/tmp/pg_hba.conf.pre_restore.$$"
    cp -a "${PGDATA}/pg_hba.conf" "${SAVED_PG_HBA}"
  fi

  if [ -f "${PGDATA}/pg_ident.conf" ]; then
    SAVED_PG_IDENT="/tmp/pg_ident.conf.pre_restore.$$"
    cp -a "${PGDATA}/pg_ident.conf" "${SAVED_PG_IDENT}"
  fi
}

restore_auth_config() {
  local restored=0

  if [ -n "${SAVED_PG_HBA:-}" ] && [ -f "${SAVED_PG_HBA}" ]; then
    cp -a "${SAVED_PG_HBA}" "${PGDATA}/pg_hba.conf"
    restored=1
  fi

  if [ -n "${SAVED_PG_IDENT:-}" ] && [ -f "${SAVED_PG_IDENT}" ]; then
    cp -a "${SAVED_PG_IDENT}" "${PGDATA}/pg_ident.conf"
    restored=1
  fi

  rm -f "${SAVED_PG_HBA:-}" "${SAVED_PG_IDENT:-}" || true

  if [ "${restored}" -eq 1 ]; then
    echo "Restored pre-restore pg_hba.conf/pg_ident.conf to preserve access rules."
  fi
}

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

# Normalize and verify path permissions before restore starts.
normalize_pgdata_permissions
assert_postgres_pgdata_access
backup_auth_config

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

restore_opts=(--set="${backup_label}" --delta --link-all)

# When backups are not enabled on this instance, prevent the restored cluster
# from archiving WAL into the production repo (which would create a new
# timeline and block future restores).
if [ "${ENABLE_DB_BACKUP:-}" != "true" ]; then
  restore_opts+=(--archive-mode=off)
fi

set +e
pgbackrest \
  --stanza=main \
  --log-level-console=detail \
  --log-level-file=off \
  restore "${restore_opts[@]}"
rc=$?
set -e

echo ""

if [ "${rc}" -eq 0 ]; then
  restore_auth_config

  # If backups are not enabled on this instance, disable WAL archiving so the
  # restored database does not push WAL to the production S3 repo.
  if [ "${ENABLE_DB_BACKUP:-}" != "true" ]; then
    auto_conf="${PGDATA}/postgresql.auto.conf"
    if [ -f "${auto_conf}" ]; then
      echo "Backup not enabled — disabling WAL archiving in postgresql.auto.conf..."
      # Remove existing archive settings then append safe defaults
      sed -i '/^\s*archive_mode\s*=/d; /^\s*archive_command\s*=/d' "${auto_conf}"
      echo "archive_mode = 'off'" >> "${auto_conf}"
      echo "archive_command = '/bin/true'" >> "${auto_conf}"
    fi
  fi

  normalize_pgdata_permissions
  assert_postgres_pgdata_access
  echo "Restore completed successfully."
  echo "Permissions validated for postgres on ${PGDATA}."
else
  echo "Restore FAILED (exit code ${rc}). See console output above."
fi

echo ""
exit "${rc}"
