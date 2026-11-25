# Restore a database

InfraWatch backups are logical dumps (`pg_dump -Fc`), one file per run, with a `.manifest` sidecar that stores the sha256. They are a snapshot of the database at dump time. They are not WAL archives, so you cannot restore to a minute between two dumps.

Paths below are the host install (`/var/backups/infrawatch`, `/var/log/infrawatch`). A checkout uses `var/backups` and `var/log` under the repo, and you run `./bin/infrawatch` instead of the `/opt/infrawatch` path.

## Before you write anything

1. Run `infrawatch triage` and keep the file it writes in the log directory.
2. Decide that the problem is data (dropped table, bad migration, database that will not come back) and not a host you can fix by starting PostgreSQL.
3. Pick a dump. The newest file is what `restore-test` uses. If that dump was taken after the bad change, use an older file.

## Check the dump

```bash
awk -F= '/^sha256=/{print $2}' /var/backups/infrawatch/app_TIMESTAM.dump.manifest
sha256sum /var/backups/infrawatch/app_TIMESTAM.dump
pg_restore --list /var/backups/infrawatch/app_TIMESTAM.dump | less
```

If the checksum does not match the manifest, do not restore that file. Use the next older dump. A mismatch means the file was truncated or changed after the backup.

## Prove it on the scratch database first

When the source database is still up:

```bash
infrawatch restore-test
```

That creates `RESTORE_SCRATCH_DB` (default `infrawatch_scratch`), restores the newest dump, and compares public-table row counts with the source. On success the scratch database is dropped. On failure it is left in place (`KEEP_SCRATCH_ON_FAILURE=1`) so you can look at it.

`restore-test` needs the source online because of the count comparison. If the source is the thing that is broken, restore into a new name instead.

## Restore into a new database

```bash
infrawatch restore \
  --dump /var/backups/infrawatch/app_TIMESTAM.dump \
  --target app_recovered
```

The command refuses when the target already exists. It also refuses to replace `PGDATABASE` unless you pass `--force`.

On a new cluster, create the role first (`sql/grants.sql`), then restore with `--no-owner` so ownership statements in the dump are skipped:

```bash
infrawatch restore --dump FILE --target app --no-owner
```

`--force` drops the target first. Do not point it at a database you still need. The restore runs in one transaction, so a failure leaves the new database empty rather than half-loaded.

## After the restore

1. Connect and run the application's checks. A matching row count is not the whole story.
2. If you used `--no-owner`, reapply grants.
3. Cut the application over during a window when nothing else is connected:

```sql
ALTER DATABASE app RENAME TO app_bad;
ALTER DATABASE app_recovered RENAME TO app;
```

4. Take a fresh backup once the recovered database is the one you will keep.

`infrawatch triage` and `pg_stat_activity` both show sessions that would block a rename.

## If the disk filled up during a backup

A failed `pg_dump` deletes its partial file. Free space by pruning only after a known-good dump has been copied off the host. `infrawatch prune` still keeps the newest `RETENTION_MIN_KEEP` dumps. Do not delete the only good copy to make room for a new one.
