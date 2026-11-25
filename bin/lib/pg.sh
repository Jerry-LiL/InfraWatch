# shellcheck shell=bash
# PostgreSQL helpers. Identifiers are restricted to a safe character set and
# then quoted, so the SQL below is not concatenating raw operator input.

validate_ident() {
  [[ "${1:-}" =~ ^[A-Za-z_][A-Za-z0-9_]{0,62}$ ]]
}

psql_q() {
  local db=$1
  shift
  psql \
    --host="$PGHOST" \
    --port="$PGPORT" \
    --username="$PGUSER" \
    --dbname="$db" \
    --no-password \
    --no-psqlrc \
    --quiet \
    --set=ON_ERROR_STOP=1 \
    "$@"
}

terminate_and_drop() {
  local name=$1
  validate_ident "$name" || die "invalid database name: ${name}"
  # DROP DATABASE IF EXISTS notices when the database is already gone.
  PGOPTIONS="-c client_min_messages=warning${PGOPTIONS:+ $PGOPTIONS}" \
    psql_q postgres -c \
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${name}' AND pid <> pg_backend_pid();" \
    >/dev/null
  PGOPTIONS="-c client_min_messages=warning${PGOPTIONS:+ $PGOPTIONS}" \
    psql_q postgres -c "DROP DATABASE IF EXISTS \"${name}\";" >/dev/null
}

recreate_database() {
  local name=$1
  terminate_and_drop "$name"
  psql_q postgres -c "CREATE DATABASE \"${name}\";" >/dev/null
}

database_exists() {
  local name=$1
  local found
  validate_ident "$name" || die "invalid database name: ${name}"
  found=$(psql_q postgres -At -c "SELECT 1 FROM pg_database WHERE datname = '${name}'")
  [[ "$found" == "1" ]]
}

# One line per public table: name=rowcount, sorted by name.
# Used to prove a restored scratch database matches the source.
table_count_report() {
  local db=$1
  psql_q "$db" -At <<'SQL'
CREATE TEMP TABLE infrawatch_counts (
    relname text PRIMARY KEY,
    n bigint NOT NULL
);
DO $$
DECLARE
    r record;
    n bigint;
BEGIN
    FOR r IN
        SELECT c.relname
        FROM pg_class c
        JOIN pg_namespace ns ON ns.oid = c.relnamespace
        WHERE ns.nspname = 'public'
          AND c.relkind = 'r'
        ORDER BY c.relname
    LOOP
        EXECUTE format('SELECT count(*) FROM public.%I', r.relname) INTO n;
        INSERT INTO infrawatch_counts (relname, n) VALUES (r.relname, n);
    END LOOP;
END $$;
SELECT relname || '=' || n FROM infrawatch_counts ORDER BY relname;
SQL
}

# Active user queries older than the threshold. Our own application_name,
# pg_dump, and pg_restore are excluded so the backup window does not page.
query_long_running() {
  local seconds=$1
  PGOPTIONS="-c statement_timeout=15s${PGOPTIONS:+ $PGOPTIONS}" \
    psql_q "$PGDATABASE" -v secs="$seconds" -At <<'SQL'
SELECT pid::text || ' ' || COALESCE(usename, '') || ' ' ||
       EXTRACT(EPOCH FROM (clock_timestamp() - query_start))::int::text || 's ' ||
       left(regexp_replace(query, '[[:space:]]+', ' ', 'g'), 100)
FROM pg_stat_activity
WHERE state = 'active'
  AND pid <> pg_backend_pid()
  AND query_start IS NOT NULL
  AND clock_timestamp() - query_start > (:'secs'::int * interval '1 second')
  AND COALESCE(application_name, '') NOT IN ('pg_dump', 'pg_restore', 'infrawatch')
ORDER BY query_start
LIMIT 10;
SQL
}
