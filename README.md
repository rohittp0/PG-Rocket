# PG Rocket

PG Rocket is a Dockerized PostGIS/PostgreSQL stack with:

- `pgBackRest` full backups to S3-compatible object storage
- WAL archiving for point-in-time recovery
- interactive restore flow from backups
- Telegram notifications for backup success/failure
- startup-time permission hardening for `PGDATA`

## What This Repository Contains

- `Dockerfile`: custom PostGIS image with `pgbackrest`, `cron`, `jq`, `curl`
- `pg-rocket-entrypoint.sh`: startup orchestrator (config, cron, preflight, post-start setup)
- `backup.sh`: scheduled/manual full backup runner with retries + Telegram
- `restore.sh`: interactive restore command with console detail logs
- `docker-compose.yml`: local service definition and volume mount
- `seed.sql`: optional init seed script

## Prerequisites

- Docker Desktop (or Docker Engine + Compose)
- Network access from container to:
  - your S3-compatible endpoint
  - Telegram API (`api.telegram.org`) if notifications are enabled

## Quick Start

1. Create `.env` from the sample file:

```bash
cp sample.env .env
```

2. Fill in real values in `.env` (S3 credentials, Telegram, database password, etc.).
3. Start the stack:

```bash
docker compose up --build
```

4. Verify service is healthy:

```bash
docker compose logs -f postgres
```

5. Trigger a manual backup if needed:

```bash
docker compose exec postgres /usr/local/bin/backup.sh
```

## Environment Variables

The container reads variables from `.env` via Compose.

### Required when backup is enabled (`ENABLE_DB_BACKUP=true`)

| Variable | Description |
|---|---|
| `POSTGRES_DB` | Database name |
| `POSTGRES_USER` | Database user |
| `POSTGRES_PASSWORD` | Database password |
| `STACK_NAME` | Logical stack name used in backup repo path |
| `S3_ENDPOINT` | S3-compatible endpoint (for example Wasabi endpoint) |
| `S3_BUCKET` | Bucket name |
| `S3_KEY` | Access key |
| `S3_SECRET` | Secret key |
| `TELEGRAM_BOT_TOKEN` | Telegram bot token used by backup notifications |
| `TELEGRAM_CHAT_ID` | Telegram target chat/channel ID |

### Optional variables (with defaults)

| Variable | Default | Description |
|---|---|---|
| `ENABLE_DB_BACKUP` | `false` | Enable/disable backup feature block |
| `S3_REGION` | `us-east-1` | S3 region |
| `BACKUP_CRON` | `0 3 * * 2` | Cron schedule for `backup.sh` |
| `BACKUP_RETAIN_COUNT` | `1` | `repo1-retention-full` |
| `MAX_RETRIES` | `5` | Backup retry attempts |
| `RETRY_SLEEP_SECONDS` | `60` | Delay between backup retries |
| `PRIMARY_READY_TIMEOUT_SECONDS` | `300` | Max wait for primary mode before post-start setup is skipped |
| `PGBACKREST_LOCK_PATH` | `/tmp/pgbackrest` | pgBackRest lock path |
| `PG_AUTO_INIT` | unset | If unset and `PGDATA` is empty, entrypoint waits for manual restore |

### Example `.env`

```dotenv
ENABLE_DB_BACKUP=true

STACK_NAME=rocket-local

POSTGRES_DB=testdb
POSTGRES_USER=testuser
POSTGRES_PASSWORD=replace-me

S3_ENDPOINT=s3.us-east-1.wasabisys.com
S3_BUCKET=replace-me
S3_KEY=replace-me
S3_SECRET=replace-me
S3_REGION=us-east-1

TELEGRAM_BOT_TOKEN=replace-me
TELEGRAM_CHAT_ID=replace-me

BACKUP_CRON=0 3 * * 2
BACKUP_RETAIN_COUNT=1
MAX_RETRIES=5
RETRY_SLEEP_SECONDS=60
PRIMARY_READY_TIMEOUT_SECONDS=300
PGBACKREST_LOCK_PATH=/tmp/pgbackrest
```

## Current Compose Behavior

Current `docker-compose.yml` includes:

- `PG_AUTO_INIT: "1"` (auto-init behavior enabled)
- `./seed.sql` mounted to `/docker-entrypoint-initdb.d/20-seed.sql`

If you want strict manual-restore-first startup, remove `PG_AUTO_INIT` from compose.

## Startup Flow

`pg-rocket-entrypoint.sh` does the following:

1. Validates critical env vars.
2. Enforces `PGDATA` directory ownership/permissions for `postgres`.
3. Writes `/etc/pgbackrest/pgbackrest.conf`.
4. Writes backup environment to `/etc/pg-rocket-env.sh`.
5. Installs cron job:
   - `BACKUP_CRON root /usr/local/bin/backup.sh`
6. Starts cron daemon.
7. If `PGDATA` is empty and `PG_AUTO_INIT` is unset, waits for manual restore.
8. Hands off to official `docker-entrypoint.sh postgres`.
9. Background post-start task:
   - waits for database readiness
   - waits until `pg_is_in_recovery()` is `false` (primary mode)
   - verifies/enables archive settings
   - runs `stanza-create` (as `postgres`)
   - runs initial full backup if no full backup exists

## Backup Behavior

`backup.sh`:

- Uses lock file `/tmp/pg-rocket-backup.lock` to prevent overlap.
- Runs `pgbackrest --stanza=main backup --type=full`.
- Retries up to `MAX_RETRIES`.
- Logs command output to `/var/log/pgbackrest/backup_YYYY-MM-DD_HHMMSS.log`.
- Sends Telegram message on success/failure, including duration and latest backup stats.

### Manual Backup Command

```bash
docker compose exec postgres /usr/local/bin/backup.sh
```

### Check Backup Metadata

```bash
docker compose exec postgres gosu postgres pgbackrest --stanza=main info
```

## Restore Behavior

`restore.sh`:

- Lists backup sets from `pgbackrest info --output=json`.
- Prompts user to select a backup label.
- Enforces and validates `PGDATA` permissions before and after restore.
- Runs restore with detailed console logs (not file-tail simulation):

```bash
pgbackrest --stanza=main --log-level-console=detail --log-level-file=off restore --set="<label>" --delta --link-all
```

- Exits non-zero on failure and prints remediation guidance for permission issues.

### Manual Restore Steps

1. Start container (if running manual-restore flow, it will wait).
2. Run:

```bash
docker compose exec postgres /usr/local/bin/restore.sh
```

3. After restore completes, PostgreSQL will continue startup/recovery.

## Logs and Where to Look

- Container logs:

```bash
docker compose logs -f postgres
```

- pgBackRest logs inside container:
  - `/var/log/pgbackrest/`
  - `cron.log`
  - per-backup log files

Restore detail output now prints directly to your terminal.

## Expected Recovery Messages

After restore, these messages are normal:

- `database system is starting up`
- `not yet accepting connections`
- `starting archive recovery`
- `consistent recovery state reached`
- `archive recovery complete`

During this window PostgreSQL may be read-only until recovery completes.

## Troubleshooting

### `mkdir: cannot create directory '/var/lib/postgresql/18': Permission denied`

Cause: ownership/permission mismatch on `PGDATA` path.

Fix (inside container as root):

```bash
chown -R postgres:postgres /var/lib/postgresql/18 && chmod 755 /var/lib/postgresql && chmod 700 /var/lib/postgresql/18 /var/lib/postgresql/18/docker
```

The current scripts already enforce this on startup and restore.

### `Found orphan containers (...)`

Compose detected old services from earlier config.

Use:

```bash
docker compose up --build --remove-orphans
```

### Backup fails with lock/permission errors under `/tmp/pgbackrest`

The stack now sets lock path and ownership explicitly. If needed:

```bash
docker compose exec postgres bash -lc 'mkdir -p /tmp/pgbackrest && chown -R postgres:postgres /tmp/pgbackrest'
```

### Backup seems slow for a small logical DB

Full backup duration includes checkpoint and object-storage overhead, not only logical row size. This stack currently runs full backups (`--type=full`) by design.

## Security Notes

- Do not commit real secrets in `.env`.
- Rotate keys/tokens immediately if they were shared or committed.
- Restrict S3 credentials to least privilege required for backup/restore.

## Useful Commands

Build and start:

```bash
docker compose up --build
```

Stop:

```bash
docker compose down
```

Stop and remove volumes (destructive):

```bash
docker compose down -v
```

Open a shell in container:

```bash
docker compose exec postgres bash
```
