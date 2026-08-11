# Time-based 90-day retention, anchored to Wasabi's minimum storage duration

We retain full backups and continuous WAL for **90 days** using
`repo1-retention-full-type=time` / `repo1-retention-full=90`, rather than retaining a
count of backup sets. 90 is not a recovery requirement — it is Wasabi's minimum storage
duration. Objects deleted before day 90 are billed to day 90 regardless, so any retention
window shorter than 90 days discards restore points that have already been paid for.

## Context

Before this decision the fleet ran `repo1-retention-full=1` with weekly full backups, so
every backup set was deleted after ~7 days. Wasabi's console showed the result: **92 GB
active storage against 950 GB of timed-deleted storage** — the bill was ~10x the data,
and it bought exactly one restore point and no usable PITR.

## Considered options

- **Shorter window to cut cost.** Saves nothing. Wasabi bills deleted objects to day 90,
  and the account also carries a 1 TB minimum monthly charge that the fleet sits at
  regardless. This is the option to re-reject when someone proposes it.

- **Monthly full + weekly differential cadence.** Rejected on measurement, not principle.
  WAL outweighs backup bytes in this fleet by roughly 2:1 to 7:1, so collapsing 14 retained
  fulls into ~4 addresses under 10% of the footprint. It would have cost a backup-type state
  machine in cron, longer restore chains, and changes throughout `backup.sh`. If backup bytes
  ever come to dominate WAL, this becomes worth revisiting — check the ratio first.

- **Longer window (e.g. 365 days).** No stack has an obligation beyond 90 days. Would cost
  ~4x the WAL footprint. If a long-tail need appears, prefer periodic logical dumps to cold
  storage over extending the PITR window.

## Consequences

- **PITR works for the first time.** Under count-based retention pgBackRest keeps continuous
  WAL for `repo1-retention-full` backup sets — one week. Under `full-type=time` it defaults to
  retaining archives back to the oldest retained full, so the 90-day window is continuously
  recoverable with no extra archive configuration. `README.md` previously advertised PITR that
  the tooling could not actually reach.

- **The retention variable changed units, so it changed name.** `repo1-retention-full` counts
  *days* once `full-type=time`. A leftover `BACKUP_RETAIN_COUNT=1` — shipped in `sample.env`
  and the README's example — would have been read as a **one-day** window, silently cutting
  retention below today's behaviour while still reporting backup success to Telegram.
  `BACKUP_RETENTION_DAYS` replaces it; `BACKUP_RETAIN_COUNT` is deliberately inert and warns.

- **Expiry only runs during a backup.** A stack whose backups have stalled does not
  self-delete, since pgBackRest expires as part of the `backup` command.

- **Footprint moves from ~1.04 TB to ~1.2 TB** — roughly $1/month — in exchange for ~14
  restore points and 90 days of point-in-time recovery. The transition is monotonic: the
  existing timed-deleted tail decays as active storage grows, so there is no billing spike.
