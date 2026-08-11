# PG Rocket

PG Rocket is a Dockerized PostgreSQL/PostGIS image that backs a fleet of independent
databases up to one shared S3-compatible bucket, with scheduled backups, Telegram
alerting, and an interactive restore path.

## Language

### Deployment

**Stack**:
One deployed PG Rocket instance, identified by `STACK_NAME`, owning exactly one database.
_Avoid_: instance, environment, service, tenant

**Fleet**:
All Stacks sharing a single S3 account and bucket. Cost and quota are fleet-wide, never per-Stack.
_Avoid_: cluster (means something else in PostgreSQL)

**Repository**:
The pgBackRest store for one Stack, at bucket prefix `/pg/<STACK_NAME>/<POSTGRES_DB>`.
Every Stack's Repository uses the stanza name `main`.
_Avoid_: bucket (the bucket holds many Repositories), repo path

### Backup and recovery

**Backup Set**:
One full backup plus any differentials/incrementals that depend on it. pgBackRest expires
a Backup Set as an indivisible unit.
_Avoid_: snapshot, backup (ambiguous between the set and the full)

**Restore Point**:
A Backup Set that `restore.sh` can restore to directly, by label.
_Avoid_: recovery point, checkpoint (means something else in PostgreSQL)

**Retention Window**:
The span of time for which recovery must remain possible, in days. Distinct from a count
of Backup Sets — see Flagged ambiguities.
_Avoid_: retain count, retention count

**PITR**:
Recovery to an arbitrary instant inside the Retention Window, by replaying WAL on top of a
Backup Set. Requires continuous WAL, not just Backup Sets.
_Avoid_: point-in-time restore, time travel

**Continuous WAL**:
An unbroken WAL sequence spanning the Retention Window. Whether it exists is what separates
real PITR from restore-to-backup-label-only.

### Storage economics

**Timed-Deleted Storage**:
Bytes deleted before Wasabi's 90-day minimum storage duration, still billed until day 90.
Wasabi reports this as "Deleted Storage".
_Avoid_: orphaned data, deleted bytes

**Billing Floor**:
Wasabi's minimum monthly charge, equivalent to 1 TB. Reducing billed bytes below it saves
nothing, which is why byte-shaving optimizations must be justified against the Floor, not
against zero.

## Relationships

- A **Fleet** contains many **Stacks**; each **Stack** owns exactly one **Repository**
- A **Repository** holds many **Backup Sets** and one **Continuous WAL** sequence
- Each **Backup Set** is one **Restore Point**
- **PITR** requires a **Backup Set** *and* **Continuous WAL** covering the target instant
- Deleting a **Backup Set** before day 90 converts its bytes into **Timed-Deleted Storage**
- The **Retention Window** governs both **Backup Set** and **Continuous WAL** expiry

## Example dialogue

> **Dev:** "We keep one backup, so our Retention Window is one week, right?"
> **Domain expert:** "No — those are different things. `BACKUP_RETAIN_COUNT=1` is a count of
> Backup Sets. The Retention Window is how far back you can recover, and with count-based
> retention it falls out as a side effect of the backup schedule rather than being stated."
> **Dev:** "So if I set the count to 1 under time-based retention?"
> **Domain expert:** "You'd get a one-*day* Window. Same number, different unit. That's why the
> variable had to be renamed rather than reinterpreted."

> **Dev:** "We advertise PITR — that's the WAL archiving, isn't it?"
> **Domain expert:** "Archiving WAL is necessary but not sufficient. Under count-based retention
> pgBackRest only kept Continuous WAL for one Backup Set, and `restore.sh` never exposed a
> recovery target. We shipped the ingredients, not the capability."

## Flagged ambiguities

- **"retention" meant two different units.** `BACKUP_RETAIN_COUNT` counted Backup Sets;
  `repo1-retention-full` counts days once `repo1-retention-full-type=time`. Resolved: the
  domain term is **Retention Window**, measured in days, exposed as `BACKUP_RETENTION_DAYS`.
  `BACKUP_RETAIN_COUNT` is retired and deliberately made inert — reinterpreting it in place
  would have silently cut every Stack's Window from 90 days to 1.

- **"backup" meant both the full and the set.** Resolved: **Backup Set** is the unit of
  expiry and of restore; "full" refers only to the `--type=full` backup within it.

- **PITR was claimed but not reachable.** `README.md:6` promised point-in-time recovery while
  `restore.sh` only ever restored to a Backup Set label. Resolved: PITR is a distinct
  capability from WAL archiving, and requires both Continuous WAL across the Retention Window
  and a recovery target in the restore flow.

- **Cost intuition was inverted.** WAL outweighs Backup Set bytes by roughly 2:1 to 7:1 in this
  Fleet, so backup *cadence* is not the cost lever it appears to be. Optimizations are judged
  against the **Billing Floor**.
