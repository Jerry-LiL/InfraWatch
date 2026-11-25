#!/usr/bin/env bash
# Needs a PostgreSQL the infrawatch role can log into, with CREATEDB and
# permission to connect to the postgres maintenance database.
# docker compose up, or a local cluster with that role, both work.
set -euo pipefail

ROOT=$(dirname "$(dirname "$(readlink -f "$0")")")
# shellcheck source=assert.sh
source "$(dirname "$(readlink -f "$0")")/assert.sh"

tmp=$(mktemp -d)
sleep_pid=""
trap 'cleanup' EXIT

cleanup() {
  set +e
  if [[ -n "$sleep_pid" ]]; then
    kill "$sleep_pid" 2>/dev/null
    wait "$sleep_pid" 2>/dev/null
  fi
  if [[ -n "${PGPASSWORD:-}" ]]; then
    PGOPTIONS="-c client_min_messages=warning" \
      psql --host="$PGHOST" --port="$PGPORT" --username="$PGUSER" --dbname=postgres \
      --no-password --no-psqlrc --quiet --set=ON_ERROR_STOP=1 \
      -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname IN ('infrawatch_it', 'infrawatch_it_scratch', 'infrawatch_it_recovered') AND pid <> pg_backend_pid();" \
      >/dev/null 2>&1
    PGOPTIONS="-c client_min_messages=warning" \
      psql --host="$PGHOST" --port="$PGPORT" --username="$PGUSER" --dbname=postgres \
      --no-password --no-psqlrc --quiet \
      -c "DROP DATABASE IF EXISTS infrawatch_it_scratch;" >/dev/null 2>&1
    PGOPTIONS="-c client_min_messages=warning" \
      psql --host="$PGHOST" --port="$PGPORT" --username="$PGUSER" --dbname=postgres \
      --no-password --no-psqlrc --quiet \
      -c "DROP DATABASE IF EXISTS infrawatch_it_recovered;" >/dev/null 2>&1
    PGOPTIONS="-c client_min_messages=warning" \
      psql --host="$PGHOST" --port="$PGPORT" --username="$PGUSER" --dbname=postgres \
      --no-password --no-psqlrc --quiet \
      -c "DROP DATABASE IF EXISTS infrawatch_it;" >/dev/null 2>&1
  fi
  rm -rf "$tmp"
}

export PGHOST=${PGHOST:-127.0.0.1}
export PGPORT=${PGPORT:-5432}
export PGUSER=${PGUSER:-infrawatch}
export PGPASSWORD=${PGPASSWORD:-infrawatch}
export PGAPPNAME=infrawatch

if ! pg_isready --host="$PGHOST" --port="$PGPORT" --username="$PGUSER" --dbname=postgres >/dev/null 2>&1; then
  printf 'PostgreSQL is not accepting connections on %s:%s as %s\n' "$PGHOST" "$PGPORT" "$PGUSER" >&2
  printf 'Start it with: docker compose up -d --wait\n' >&2
  printf 'Or create the role on a local cluster and export PGHOST/PGUSER/PGPASSWORD.\n' >&2
  exit 1
fi

psql_pg() {
  PGOPTIONS="-c client_min_messages=warning${PGOPTIONS:+ $PGOPTIONS}" \
    psql --host="$PGHOST" --port="$PGPORT" --username="$PGUSER" --dbname="$1" \
    --no-password --no-psqlrc --quiet --set=ON_ERROR_STOP=1 "${@:2}"
}

psql_pg postgres -c "DROP DATABASE IF EXISTS infrawatch_it;" >/dev/null
psql_pg postgres -c "CREATE DATABASE infrawatch_it;" >/dev/null
psql_pg infrawatch_it -f "$ROOT/sql/sample_schema.sql" >/dev/null

write_env() {
  local disk=$1 queries=$2 keep=$3 state=$4
  cat > "$tmp/env" <<EOF
PGHOST=$PGHOST
PGPORT=$PGPORT
PGUSER=$PGUSER
PGPASSWORD=$PGPASSWORD
PGDATABASE=infrawatch_it
BACKUP_DIR=$tmp/backups
LOG_DIR=$tmp/log
STATE_DIR=$state
RETENTION_DAYS=14
RETENTION_MIN_KEEP=3
RESTORE_SCRATCH_DB=infrawatch_it_scratch
KEEP_SCRATCH=$keep
KEEP_SCRATCH_ON_FAILURE=1
CPU_LOAD_PER_CORE=1000
MEM_USED_PERCENT=100
DISK_USED_PERCENT=$disk
DISK_PATHS=/
SYSTEMD_UNITS=
LONG_QUERY_SECONDS=$queries
ALERT_REPEAT_SECONDS=3600
EOF
}

export INFRAWATCH_ROOT=$ROOT
export INFRAWATCH_ENV=$tmp/env

cli() {
  "$ROOT/bin/infrawatch" "$@"
}

write_env 100 86400 0 "$tmp/state"
cli backup >"$tmp/backup.out" 2>"$tmp/backup.err"
mapfile -t dumps < <(find "$tmp/backups" -name '*.dump' | sort)
assert_eq "${#dumps[@]}" 1 "backup writes one dump"
manifest=${dumps[0]%.dump}.manifest
test -f "$manifest"
grep -q '^status=ok$' "$manifest"
# The sidecar matches the file we just wrote.
sha=$(awk -F= '$1=="sha256"{print $2}' "$manifest")
actual=$(sha256sum "${dumps[0]}" | awk '{print $1}')
assert_eq "$actual" "$sha" "manifest sha256 matches the dump"

write_env 100 86400 1 "$tmp/state"
cli restore-test >"$tmp/rt.out" 2>"$tmp/rt.err"
grep -q 'status=ok' "$tmp/log/restore-tests.log"
scratch_count=$(psql_pg postgres -At -c "SELECT count(*) FROM pg_database WHERE datname = 'infrawatch_it_scratch'")
assert_eq "$scratch_count" 1 "KEEP_SCRATCH leaves the scratch database"
ada=$(psql_pg infrawatch_it_scratch -At -c "SELECT email FROM customers WHERE email = 'ada@example.com'")
assert_eq "$ada" "ada@example.com" "scratch restore contains source rows"
psql_pg postgres -c "DROP DATABASE infrawatch_it_scratch;" >/dev/null

psql_pg infrawatch_it -c \
  "INSERT INTO customers (email, name) VALUES ('restore-check@example.com', 'Restore Check');" >/dev/null
write_env 100 86400 0 "$tmp/state2"
cli backup >/dev/null
cli restore-test >/dev/null
grep -q 'status=ok' "$tmp/log/restore-tests.log"

# Explicit restore into a side database, then a refusal to clobber it.
dump=$(find "$tmp/backups" -name '*.dump' -printf '%T@ %p\n' | sort -nr | head -n 1 | cut -d' ' -f2-)
cli restore --dump "$dump" --target infrawatch_it_recovered >/dev/null
found=$(psql_pg infrawatch_it_recovered -At -c "SELECT count(*) FROM customers WHERE email = 'restore-check@example.com'")
assert_eq "$found" 1 "restore --target loads the extra row"

set +e
cli restore --dump "$dump" --target infrawatch_it_recovered >"$tmp/out" 2>"$tmp/err"
rc=$?
set -e
assert_eq "$rc" 1 "restore refuses an existing target without --force"
grep -q 'already exists' "$tmp/err"

# Retention: age the older dump out and keep only the newest.
mapfile -t dumps < <(find "$tmp/backups" -name '*.dump' -printf '%T@ %p\n' | sort -n | awk '{print $2}')
assert_eq "${#dumps[@]}" 2 "two backups are on disk"
touch -d '40 days ago' "${dumps[0]}"
cat > "$tmp/env" <<EOF
PGHOST=$PGHOST
PGPORT=$PGPORT
PGUSER=$PGUSER
PGPASSWORD=$PGPASSWORD
PGDATABASE=infrawatch_it
BACKUP_DIR=$tmp/backups
LOG_DIR=$tmp/log
STATE_DIR=$tmp/state-prune
RETENTION_DAYS=14
RETENTION_MIN_KEEP=1
RESTORE_SCRATCH_DB=infrawatch_it_scratch
SYSTEMD_UNITS=
LONG_QUERY_SECONDS=0
EOF
cli prune >/dev/null
left=$(find "$tmp/backups" -name '*.dump' | wc -l)
left=${left// /}
assert_eq "$left" 1 "prune keeps the newest dump and drops the old one"
[[ -f "${dumps[1]}" ]]
[[ ! -f "${dumps[0]}" ]]
[[ ! -f "${dumps[0]%.dump}.manifest" ]]

# Disk threshold one point below the live usage, so the breach does not depend
# on a particular machine being almost full.
used=$(df -P / | awk 'NR == 2 { gsub(/%/, "", $5); print $5 }')
if ((used > 0)); then
  write_env $((used - 1)) 86400 0 "$tmp/state-disk"
  set +e
  cli health >"$tmp/health.out" 2>"$tmp/health.err"
  rc=$?
  set -e
  assert_eq "$rc" 1 "disk threshold breach exits 1"
  grep -q '^disk / alert ' "$tmp/health.out"
  grep -q 'severity=warning check=disk /' "$tmp/log/alerts.log"
fi

# A session sleeping past the threshold is a long query.
PGAPPNAME=app_test psql_pg infrawatch_it -c "SELECT pg_sleep(30);" >/dev/null 2>&1 &
sleep_pid=$!
seen=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  n=$(PGAPPNAME=infrawatch psql_pg infrawatch_it -At -c \
    "SELECT count(*) FROM pg_stat_activity
     WHERE application_name = 'app_test'
       AND state = 'active'
       AND clock_timestamp() - query_start > interval '1 second'")
  if [[ "${n:-0}" -ge 1 ]]; then
    seen=1
    break
  fi
  sleep 0.3
done
assert_eq "$seen" 1 "pg_sleep session is visible"
write_env 100 1 0 "$tmp/state-query"
set +e
cli health >"$tmp/health.out" 2>"$tmp/health.err"
rc=$?
set -e
assert_eq "$rc" 1 "long query exits 1"
grep -q 'pg_sleep' "$tmp/health.out"
kill "$sleep_pid" 2>/dev/null || true
wait "$sleep_pid" 2>/dev/null || true
sleep_pid=""

cli triage >"$tmp/triage.out"
grep -q 'checksum=ok' "$tmp/triage.out"
grep -q 'last_restore_test=' "$tmp/triage.out"

finish
printf 'integration ok\n'
