# shellcheck shell=bash
# pg_dump in custom format, plus a sidecar manifest with the sha256.
# Restore refuses a dump whose checksum does not match.

read_manifest_field() {
  local file=$1 key=$2
  awk -F= -v k="$key" '$1 == k { print substr($0, index($0, "=") + 1); exit }' "$file"
}

write_manifest() {
  local dump=$1
  local manifest="${dump%.dump}.manifest"
  local sum size version
  sum=$(sha256sum -- "$dump" | awk 'NR == 1 { print $1 }')
  size=$(stat -c %s -- "$dump")
  version=$(pg_dump --version | awk '{ print $3 }')
  cat > "$manifest" <<EOF
file=$(basename -- "$dump")
database=${PGDATABASE}
format=custom
created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
size_bytes=${size}
sha256=${sum}
pg_dump_version=${version}
status=ok
EOF
  chmod 600 "$dump" "$manifest"
}

verify_manifest() {
  local dump=$1
  local manifest="${dump%.dump}.manifest"
  local expected actual
  [[ -f "$dump" && -f "$manifest" ]] || return 1
  expected=$(read_manifest_field "$manifest" sha256)
  [[ -n "$expected" ]] || return 1
  actual=$(sha256sum -- "$dump" | awk 'NR == 1 { print $1 }')
  [[ "$expected" == "$actual" ]]
}

_run_backup() {
  local stamp file old_umask removed
  stamp=$(date -u +%Y%m%dT%H%M%S%N)
  file="${BACKUP_DIR}/${PGDATABASE}_${stamp}.dump"
  old_umask=$(umask)
  umask 077
  log_info "backup start database=${PGDATABASE} file=${file}"
  if ! pg_dump \
    --host="$PGHOST" \
    --port="$PGPORT" \
    --username="$PGUSER" \
    --dbname="$PGDATABASE" \
    --format=custom \
    --no-password \
    --file="$file"
  then
    rm -f -- "$file"
    umask "$old_umask"
    die "pg_dump failed for ${PGDATABASE}"
  fi
  if [[ ! -s "$file" ]]; then
    rm -f -- "$file"
    umask "$old_umask"
    die "pg_dump produced an empty file for ${PGDATABASE}"
  fi
  write_manifest "$file"
  umask "$old_umask"
  say "backup ok file=$(basename -- "$file") bytes=$(stat -c %s -- "$file")"

  removed=$(prune_backups "$BACKUP_DIR" "$RETENTION_DAYS" "$RETENTION_MIN_KEEP" || true)
  if [[ -n "$removed" ]]; then
    log_info "pruned ${removed//$'\n'/,}"
  fi
}

run_backup() {
  [[ $# -eq 0 ]] || die "backup takes no arguments"
  is_uint "${RETENTION_DAYS:-}" || die "RETENTION_DAYS must be an integer"
  is_uint "${RETENTION_MIN_KEEP:-}" || die "RETENTION_MIN_KEEP must be an integer"
  require_cmd pg_dump sha256sum
  with_lock backup _run_backup
}

_run_prune() {
  local removed
  removed=$(prune_backups "$BACKUP_DIR" "$RETENTION_DAYS" "$RETENTION_MIN_KEEP" || true)
  if [[ -z "$removed" ]]; then
    say "prune kept all dumps in ${BACKUP_DIR}"
  else
    say "prune removed ${removed//$'\n'/,}"
  fi
}

run_prune() {
  [[ $# -eq 0 ]] || die "prune takes no arguments"
  is_uint "${RETENTION_DAYS:-}" || die "RETENTION_DAYS must be an integer"
  is_uint "${RETENTION_MIN_KEEP:-}" || die "RETENTION_MIN_KEEP must be an integer"
  with_lock backup _run_prune
}
