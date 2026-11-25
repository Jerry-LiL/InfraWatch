# shellcheck shell=bash
# Restore tests load the newest dump into a scratch database and compare
# public table row counts with the source. A real restore goes to an explicit
# target and will not replace a database unless --force is set.

record_restore_result() {
  local status=$1 dump=$2 started=$3
  local elapsed
  elapsed=$(( $(date +%s) - started ))
  printf '%s status=%s dump=%s seconds=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$status" \
    "$(basename -- "$dump")" \
    "$elapsed" \
    >> "$LOG_DIR/restore-tests.log"
  printf '%s\n' "$elapsed"
}

maybe_drop_scratch() {
  local status=$1
  local drop=0
  if [[ "$status" == "ok" && "${KEEP_SCRATCH:-0}" != "1" ]]; then
    drop=1
  elif [[ "$status" != "ok" && "${KEEP_SCRATCH_ON_FAILURE:-1}" != "1" ]]; then
    drop=1
  fi
  if [[ "$drop" -eq 1 ]]; then
    terminate_and_drop "$RESTORE_SCRATCH_DB"
    return 0
  fi
  say "restore-test left scratch database ${RESTORE_SCRATCH_DB} in place"
}

_run_restore_test() {
  local dump started status src dst elapsed
  dump=$(latest_dump) || die "no dump found in ${BACKUP_DIR}"
  verify_manifest "$dump" || die "checksum failed for ${dump}"
  pg_restore --list -- "$dump" >/dev/null || die "pg_restore cannot read ${dump}"

  started=$(date +%s)
  log_info "restore-test start dump=$(basename -- "$dump") scratch=${RESTORE_SCRATCH_DB}"
  recreate_database "$RESTORE_SCRATCH_DB"

  status=ok
  if ! pg_restore \
    --host="$PGHOST" \
    --port="$PGPORT" \
    --username="$PGUSER" \
    --dbname="$RESTORE_SCRATCH_DB" \
    --no-password \
    --exit-on-error \
    --single-transaction \
    --no-owner \
    --no-privileges \
    -- "$dump"
  then
    status=failed
    log_error "pg_restore failed for ${dump}"
  fi

  if [[ "$status" == "ok" ]]; then
    src=$(table_count_report "$PGDATABASE")
    dst=$(table_count_report "$RESTORE_SCRATCH_DB")
    if [[ "$src" != "$dst" ]]; then
      status=mismatch
      log_error "restore-test count mismatch source=[${src//$'\n'/,}] scratch=[${dst//$'\n'/,}]"
    fi
  fi

  maybe_drop_scratch "$status"
  elapsed=$(record_restore_result "$status" "$dump" "$started")

  if [[ "$status" != "ok" ]]; then
    emit_alert error restore-test "status=${status} dump=$(basename -- "$dump")"
    return 1
  fi
  say "restore-test ok dump=$(basename -- "$dump") seconds=${elapsed}"
}

run_restore_test() {
  [[ $# -eq 0 ]] || die "restore-test takes no arguments"
  validate_ident "${RESTORE_SCRATCH_DB:-}" || die "RESTORE_SCRATCH_DB is not a valid identifier"
  if [[ "$RESTORE_SCRATCH_DB" == "$PGDATABASE" ]]; then
    die "RESTORE_SCRATCH_DB must differ from PGDATABASE"
  fi
  require_cmd pg_restore psql sha256sum
  with_lock restore _run_restore_test
}

restore_usage() {
  cat <<'EOF'
Usage: infrawatch restore --dump FILE --target DATABASE [--force] [--no-owner]

Refuses to replace PGDATABASE or an existing database unless --force is set.
--no-owner skips ownership statements from the dump (a new cluster needs this
after the role in sql/grants.sql has been created).
EOF
}

run_restore() {
  local dump="" target="" force=0 no_owner=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dump)
        [[ $# -ge 2 ]] || die "restore --dump requires a file"
        dump=$2
        shift 2
        ;;
      --target)
        [[ $# -ge 2 ]] || die "restore --target requires a database name"
        target=$2
        shift 2
        ;;
      --force)
        force=1
        shift
        ;;
      --no-owner)
        no_owner=1
        shift
        ;;
      --help | -h)
        restore_usage
        return 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done

  [[ -n "$dump" && -n "$target" ]] || die "restore requires --dump and --target"
  validate_ident "$target" || die "invalid target database name: ${target}"
  # Refuse before touching the cluster or the file, so a bad target name fails closed.
  if [[ "$target" == "$PGDATABASE" && "$force" -ne 1 ]]; then
    die "refusing to restore over source database ${PGDATABASE} without --force"
  fi
  [[ -f "$dump" ]] || die "dump not found: ${dump}"
  verify_manifest "$dump" || die "checksum failed for ${dump}"
  pg_restore --list -- "$dump" >/dev/null || die "pg_restore cannot read ${dump}"

  require_cmd pg_restore psql
  with_lock restore _run_restore "$dump" "$target" "$force" "$no_owner"
}

_run_restore() {
  local dump=$1 target=$2 force=$3 no_owner=$4
  local exists=0
  local -a args
  if database_exists "$target"; then
    exists=1
  fi
  if [[ "$exists" -eq 1 && "$force" -ne 1 ]]; then
    die "database ${target} already exists; pass --force to replace it"
  fi

  log_info "restore start dump=$(basename -- "$dump") target=${target} force=${force}"
  if [[ "$exists" -eq 1 ]]; then
    terminate_and_drop "$target"
  fi
  psql_q postgres -c "CREATE DATABASE \"${target}\";" >/dev/null

  args=(
    --host="$PGHOST"
    --port="$PGPORT"
    --username="$PGUSER"
    --dbname="$target"
    --no-password
    --exit-on-error
    --single-transaction
  )
  if [[ "$no_owner" -eq 1 ]]; then
    args+=(--no-owner --no-privileges)
  fi
  # One transaction: a failed restore leaves the new database empty, not half-loaded.
  if ! pg_restore "${args[@]}" -- "$dump"; then
    log_error "pg_restore failed; ${target} was left empty"
    return 1
  fi
  say "restore ok target=${target}"
}
