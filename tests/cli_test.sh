#!/usr/bin/env bash
set -euo pipefail

ROOT=$(dirname "$(dirname "$(readlink -f "$0")")")
# shellcheck source=assert.sh
source "$(dirname "$(readlink -f "$0")")/assert.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/env" <<EOF
PGHOST=127.0.0.1
PGPORT=5432
PGUSER=infrawatch
PGDATABASE=app
BACKUP_DIR=$tmp/backups
LOG_DIR=$tmp/log
STATE_DIR=$tmp/state
RETENTION_DAYS=14
RETENTION_MIN_KEEP=3
CPU_LOAD_PER_CORE=1000
MEM_USED_PERCENT=100
DISK_USED_PERCENT=100
DISK_PATHS=/
SYSTEMD_UNITS=
LONG_QUERY_SECONDS=0
ALERT_REPEAT_SECONDS=3600
EOF

export INFRAWATCH_ROOT=$ROOT
export INFRAWATCH_ENV=$tmp/env

cli() {
  "$ROOT/bin/infrawatch" "$@"
}

set +e
cli >/dev/null 2>&1
rc=$?
set -e
assert_eq "$rc" 2 "no command is a usage error"

set +e
cli help >/dev/null
rc=$?
set -e
assert_eq "$rc" 0 "help exits 0"

set +e
cli no-such >/dev/null 2>&1
rc=$?
set -e
assert_eq "$rc" 2 "unknown command exits 2"

# Bad retention fails before any database connection.
sed -i 's/^RETENTION_DAYS=.*/RETENTION_DAYS=soon/' "$tmp/env"
set +e
cli prune >"$tmp/out" 2>"$tmp/err"
rc=$?
set -e
assert_eq "$rc" 1 "bad RETENTION_DAYS is rejected"
grep -q 'RETENTION_DAYS must be an integer' "$tmp/err"

sed -i 's/^RETENTION_DAYS=.*/RETENTION_DAYS=14/' "$tmp/env"
set +e
cli restore --dump "$tmp/missing.dump" --target app >"$tmp/out" 2>"$tmp/err"
rc=$?
set -e
assert_eq "$rc" 1 "restore refuses the source database without --force"
grep -q 'refusing to restore over source database' "$tmp/err"

set +e
cli restore --dump "$tmp/missing.dump" --target 'app;drop' >"$tmp/out" 2>"$tmp/err"
rc=$?
set -e
assert_eq "$rc" 1 "restore rejects a target that is not an identifier"
grep -q 'invalid target database name' "$tmp/err"

# Second backup must lose the lock while the first holder still has it.
sed -i 's/^RETENTION_DAYS=.*/RETENTION_DAYS=14/' "$tmp/env"
mkdir -p "$tmp/state"
(
  flock -n 9
  sleep 30
) 9>"$tmp/state/backup.lock" &
holder=$!
sleep 0.3
set +e
cli backup >"$tmp/out" 2>"$tmp/err"
rc=$?
set -e
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
assert_eq "$rc" 1 "backup exits when the lock is held"
grep -q 'another backup is already running' "$tmp/err"

# Healthy thresholds, query check disabled. systemd is observed for real.
cat > "$tmp/env" <<EOF
PGHOST=127.0.0.1
PGPORT=5432
PGUSER=infrawatch
PGDATABASE=app
BACKUP_DIR=$tmp/backups
LOG_DIR=$tmp/log
STATE_DIR=$tmp/state-health
RETENTION_DAYS=14
RETENTION_MIN_KEEP=3
CPU_LOAD_PER_CORE=1000
MEM_USED_PERCENT=100
DISK_USED_PERCENT=100
DISK_PATHS=/
SYSTEMD_UNITS=
LONG_QUERY_SECONDS=0
ALERT_REPEAT_SECONDS=3600
EOF

set +e
cli health >"$tmp/out" 2>"$tmp/err"
rc=$?
set -e
assert_eq "$rc" 0 "health is ok when every threshold is wide open"
grep -q '^cpu ok ' "$tmp/out"
grep -q '^memory ok ' "$tmp/out"
grep -q '^disk / ok ' "$tmp/out"
grep -q '^health status=ok$' "$tmp/out"

# Ask systemd about a unit and require the tool to agree with systemctl itself.
sys_out=$(systemctl is-active postgresql 2>"$tmp/syserr" || true)
sys_out=${sys_out%%$'\n'*}
cat > "$tmp/env" <<EOF
PGHOST=127.0.0.1
PGPORT=5432
PGUSER=infrawatch
PGDATABASE=app
BACKUP_DIR=$tmp/backups
LOG_DIR=$tmp/log
STATE_DIR=$tmp/state-systemd
RETENTION_DAYS=14
RETENTION_MIN_KEEP=3
CPU_LOAD_PER_CORE=1000
MEM_USED_PERCENT=100
DISK_USED_PERCENT=100
DISK_PATHS=/
SYSTEMD_UNITS=postgresql
LONG_QUERY_SECONDS=0
ALERT_REPEAT_SECONDS=3600
EOF

set +e
cli health >"$tmp/out" 2>"$tmp/err"
rc=$?
set -e
if [[ -z "$sys_out" ]]; then
  assert_eq "$rc" 2 "systemd bus down is an error, not a pass"
  grep -q '^service postgresql error ' "$tmp/out"
elif [[ "$sys_out" == "active" ]]; then
  assert_eq "$rc" 0 "active postgresql unit passes"
  grep -q '^service postgresql ok ' "$tmp/out"
else
  assert_eq "$rc" 1 "non-active postgresql unit alerts"
  grep -q '^service postgresql alert ' "$tmp/out"
fi

set +e
cli logs -n 5 >"$tmp/out" 2>"$tmp/err"
rc=$?
set -e
assert_eq "$rc" 0 "logs falls back to the file when journald has nothing"
grep -q 'journald has no infrawatch entries' "$tmp/err" || grep -q 'level=' "$tmp/out"

set +e
cli triage >"$tmp/out" 2>"$tmp/err"
rc=$?
set -e
assert_eq "$rc" 0 "triage writes a report"
grep -q '== disk ==' "$tmp/out"
grep -q '== systemd ==' "$tmp/out"
grep -q 'newest_dump=' "$tmp/out"
find "$tmp/log" -name 'triage-*.txt' | grep -q .

finish
