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
# Fetch repository state
# -------------------------
echo ""
echo "Fetching repository information..."
echo ""

backup_json="$(pgbackrest --stanza=main info --output=json)"

backup_count="$(echo "${backup_json}" | jq '.[0].backup | length')"

if [ "${backup_count}" -eq 0 ]; then
  echo "No backups found in repository."
  exit 1
fi

format_epoch() {
  date -u -d "@${1}" '+%Y-%m-%d %H:%M:%S+00'
}

# The oldest retained backup set bounds how far back recovery can reach: WAL
# earlier than it was expired along with the backup set it belonged to.
oldest_stop="$(echo "${backup_json}" | jq -r '.[0].backup[0].timestamp.stop')"

# Distinct timelines in the repository, taken from the first 8 hex digits of each
# backup's starting WAL segment. More than one means an earlier recovery was
# promoted and forked history.
timeline_count="$(echo "${backup_json}" \
  | jq -r '[.[0].backup[].archive.start // empty | .[0:8]] | unique | length')"

list_backups() {
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
}

# -------------------------
# Mode selection
# -------------------------
echo "Recovery modes:"
echo ""
echo "  [1] Restore a backup set    — rebuild from this backup, then roll forward to the newest state"
echo "  [2] Point-in-time recovery  — rebuild and stop at a chosen instant"
echo "  [0] Cancel"
echo ""

read -rp "Select mode [0-2]: " mode

case "${mode}" in
  0|"") echo "Cancelled."; exit 0 ;;
  1|2) ;;
  *) echo "Invalid selection."; exit 1 ;;
esac

if [ "${mode}" = "1" ]; then
  # -------------------------
  # Mode 1 — restore a specific backup set
  # -------------------------
  echo ""
  echo "Available backup sets:"
  echo ""
  list_backups
  echo ""
  echo "  [0] Cancel"
  echo ""

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

  # No --type is passed, so pgBackRest uses type=default: "recover to the end of
  # the archive stream". Recovery does NOT stop at the selected backup — it
  # rebuilds from it and then replays every WAL segment archived since. That is
  # the right behaviour for disaster recovery, but it means picking an older
  # backup set here does not travel back in time. Mode 2 is what does that.
  restore_opts=(--set="${backup_label}" --delta --link-all)
  restore_desc="Restoring backup set ${backup_label}..."
  restore_summary="Mode       : restore backup set
Backup set : ${backup_label} (${backup_type}, started ${backup_time})
Recovery   : rolls forward to the NEWEST state in the archive, not to this
             backup's own point in time"

  if [ "${idx}" -ne "$((backup_count - 1))" ]; then
    restore_summary="${restore_summary}

             You picked a backup set that is not the newest. Recovery will
             still roll forward to the present. If you meant to go back to an
             earlier moment, cancel and use point-in-time recovery instead."
  fi
else
  # -------------------------
  # Mode 2 — point-in-time recovery
  # -------------------------
  echo ""
  echo "Recoverable window:"
  echo ""
  echo "  Earliest : $(format_epoch "${oldest_stop}")  (oldest retained backup set)"
  echo "  Latest   : $(date -u '+%Y-%m-%d %H:%M:%S+00')  (now)"
  echo ""
  echo "Targets outside this window cannot be satisfied — the WAL is gone."
  echo "Format: YYYY-MM-DD HH:MM:SS+00"
  echo ""

  read -rp "Recovery target timestamp (blank to cancel): " target_input

  if [ -z "${target_input}" ]; then
    echo "Cancelled."
    exit 0
  fi

  if ! target_epoch="$(date -u -d "${target_input}" +%s 2>/dev/null)"; then
    echo "ERROR: could not parse '${target_input}' as a timestamp."
    echo "       Expected format: YYYY-MM-DD HH:MM:SS+00"
    exit 1
  fi

  now_epoch="$(date -u +%s)"

  if [ "${target_epoch}" -lt "${oldest_stop}" ]; then
    echo "ERROR: target $(format_epoch "${target_epoch}") precedes the oldest retained"
    echo "       backup set ($(format_epoch "${oldest_stop}")). The WAL needed to reach"
    echo "       that point has already been expired."
    exit 1
  fi

  if [ "${target_epoch}" -gt "${now_epoch}" ]; then
    echo "ERROR: target $(format_epoch "${target_epoch}") is in the future."
    exit 1
  fi

  # pgBackRest selects the backup set itself for a time target, and the docs note
  # that forcing --set is less reliable. Compute the likely choice for display
  # only, so the operator can sanity-check before committing.
  expected_label="$(echo "${backup_json}" \
    | jq -r --argjson t "${target_epoch}" \
        '[.[0].backup[] | select(.timestamp.stop <= $t)] | last | .label // "none"')"

  if [ "${expected_label}" = "none" ]; then
    echo "ERROR: no backup set completes before $(format_epoch "${target_epoch}")."
    echo "       Recovery must start from a backup that predates the target."
    exit 1
  fi

  target_string="$(format_epoch "${target_epoch}")"

  restore_opts=(--delta --link-all --type=time --target="${target_string}" --target-action=promote)
  restore_desc="Recovering to ${target_string}..."
  restore_summary="Mode       : point-in-time recovery
Target     : ${target_string}
Backup set : ${expected_label} (expected — pgBackRest makes the final choice)
On target  : promote — cluster comes up read-write on a NEW timeline"
fi

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
echo ""
echo "---------------------------------------------------------------"
echo "${restore_summary}"
echo "Target dir : ${PGDATA}"
echo "---------------------------------------------------------------"

if [ "${timeline_count}" -gt 1 ]; then
  echo ""
  echo "NOTE: this repository spans ${timeline_count} timelines, so a previous recovery"
  echo "      was promoted at some point. Recovery follows the latest timeline by"
  echo "      default, which may not be the branch you have in mind."
fi

echo ""
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
echo "${restore_desc}"
echo ""

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
