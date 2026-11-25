# First response on the database host

Run this before restarting services or cancelling queries.

```bash
infrawatch triage
```

The command prints a report and writes the same text to `triage-<timestamp>.txt` in the log directory. It does not change PostgreSQL and it does not update alert state. `infrawatch health` is the command that raises alerts.

Production log directory is `/var/log/infrawatch`. A checkout uses `var/log` under the repo.

## CPU

The health check divides the 1-minute load average by the CPU count and alerts above `CPU_LOAD_PER_CORE` (default 1.5).

```bash
top -b -n 1 | head -n 20
ps -eo pid,user,pcpu,pmem,comm --sort=-pcpu | head
```

`pg_dump` or `pg_restore` during the backup window (02:15, restore test at 03:30) is expected. Outside that window, write down the backend and the query before you cancel anything.

## Memory

The check uses `MemAvailable` from `/proc/meminfo`, not `MemFree`. Available is what the kernel can give a new allocation without a hard reclaim. The alert fires when `(MemTotal - MemAvailable) / MemTotal` is above `MEM_USED_PERCENT` (default 90).

```bash
journalctl -k --since "6 hours ago" --no-pager | grep -i 'out of memory'
dmesg -T | grep -i 'out of memory'
```

If journald is not keeping kernel logs, `dmesg` is the one that still has them.

## Disk

```bash
df -hP / /var
du -sh /var/backups/infrawatch
```

The alert threshold is `DISK_USED_PERCENT` (default 85). If the backup directory is what filled the disk:

1. Confirm a recent dump's sha256 matches its manifest.
2. Copy that dump off the host.
3. Then `infrawatch prune`.

Prune removes the `.manifest` sidecar with the dump, and it will not delete the newest `RETENTION_MIN_KEEP` files even when they are older than `RETENTION_DAYS`.

## systemd and PostgreSQL

```bash
systemctl status postgresql
journalctl -u postgresql --since "2 hours ago" --no-pager -n 100
```

`infrawatch health` alerts when a configured unit is anything other than `active`. If it cannot talk to systemd at all, that check is an error (exit 2), not a quiet pass. `SYSTEMD_UNITS` in the config is the list.

If PostgreSQL is down, start it once the disk is not full and the data directory is mounted:

```bash
systemctl start postgresql
```

If it fails again, read the journal before the next start. A loop of start and stop hides the first error.

## Queries

Sessions active longer than `LONG_QUERY_SECONDS` (default 300) are listed. `pg_dump`, `pg_restore`, and this toolkit's own connections (`application_name=infrawatch`) are left out, so the nightly dump does not page.

```bash
psql -c "SELECT pid, usename, state, now() - query_start AS age, left(query, 200)
         FROM pg_stat_activity
         WHERE state <> 'idle'
         ORDER BY query_start"
```

`pg_cancel_backend(pid)` is the first step. `pg_terminate_backend(pid)` is for a session that ignores the cancel. The triage file already has the query text; keep it.

The role needs `pg_monitor` (see `sql/grants.sql`) or the activity view only shows its own sessions.

## Backups and alerts

The bottom of the triage report names the newest dump, whether the checksum matches, and the last restore-test line. If that line is not `status=ok`, follow the restore runbook before you trust the dump.

```bash
infrawatch logs --since "1 day ago"
tail -n 50 /var/log/infrawatch/alerts.log
```

On a host where journald has no entries, `infrawatch logs` prints the file log instead. Alerts are also sent with `logger -t infrawatch`, so `journalctl -t infrawatch` is the same stream when the journal is up.

A check that stays in breach alerts once, then again after `ALERT_REPEAT_SECONDS` (default 1 hour), not on every 5-minute tick. A recovery writes a `severity=ok` line.

## While you are looking

- Leave the backup timer alone unless the job is filling the disk.
- Do not drop `infrawatch_scratch` after a failed restore test until you have looked at it.
- Copy the triage file, the newest dump name, and the last restore-test line into the incident notes before you change anything.
