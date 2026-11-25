# shellcheck shell=bash
# Read-only views: journal/file logs, and a first-response triage report.
# Triage does not write alert state and does not change PostgreSQL.

journal_available() {
  local out
  command -v journalctl >/dev/null 2>&1 || return 1
  out=$(journalctl -t infrawatch --no-pager -n 1 2>&1 || true)
  if grep -q 'No journal files were found' <<< "$out"; then
    return 1
  fi
  if grep -q 'Failed to connect' <<< "$out"; then
    return 1
  fi
  return 0
}

run_logs() {
  local lines=100 since=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n)
        [[ $# -ge 2 ]] || die "logs -n requires a number"
        lines=$2
        is_uint "$lines" || die "logs -n requires a number"
        shift 2
        ;;
      --since)
        [[ $# -ge 2 ]] || die "logs --since requires a value"
        since=$2
        shift 2
        ;;
      --help | -h)
        cat <<'EOF'
Usage: infrawatch logs [-n LINES] [--since WHEN]

Prefers `journalctl -t infrawatch`. Falls back to the file log when journald
has no entries for this host.
EOF
        return 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done

  if journal_available; then
    local -a args
    args=(-t infrawatch --no-pager)
    if [[ -n "$since" ]]; then
      args+=(--since "$since")
    else
      args+=(-n "$lines")
    fi
    journalctl "${args[@]}"
    return
  fi

  printf 'journald has no infrawatch entries; showing %s\n' "${LOG_DIR}/infrawatch.log" >&2
  if [[ ! -f "$LOG_DIR/infrawatch.log" ]]; then
    printf 'no log file yet\n' >&2
    return 1
  fi
  tail -n "$lines" "$LOG_DIR/infrawatch.log"
}

triage_queries() {
  local rows rc=0
  if [[ "${LONG_QUERY_SECONDS:-0}" == "0" ]]; then
    printf 'long-query check disabled\n'
    return 0
  fi
  rows=$(query_long_running "$LONG_QUERY_SECONDS" 2>&1) || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    printf 'could not read pg_stat_activity\n%s\n' "$rows"
    return 0
  fi
  if [[ -z "$rows" ]]; then
    printf 'none over %ss (excluding pg_dump, pg_restore, infrawatch)\n' "$LONG_QUERY_SECONDS"
    return 0
  fi
  printf '%s\n' "$rows"
}

triage_units() {
  local -a units=()
  local unit out
  if [[ -z "${SYSTEMD_UNITS// /}" ]]; then
    printf 'no SYSTEMD_UNITS configured\n'
    return 0
  fi
  read -r -a units <<< "$SYSTEMD_UNITS"
  for unit in "${units[@]}"; do
    [[ -n "$unit" ]] || continue
    if ! command -v systemctl >/dev/null 2>&1; then
      printf '%s state=unknown detail=systemctl-not-found\n' "$unit"
      continue
    fi
    out=$(systemctl is-active "$unit" 2>&1 || true)
    printf '%s %s\n' "$unit" "$out"
    if [[ "$out" != "active" ]]; then
      systemctl status "$unit" --no-pager -n 20 || true
      if command -v journalctl >/dev/null 2>&1; then
        journalctl -u "$unit" --since "2 hours ago" --no-pager -n 40 || true
      fi
    fi
  done
}

run_triage() {
  [[ $# -eq 0 ]] || die "triage takes no arguments"
  local ts file dump
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  file="${LOG_DIR}/triage-${ts}.txt"
  mkdir -p "$LOG_DIR"

  {
    printf 'InfraWatch triage %s\n' "$ts"
    printf 'host=%s\n' "$(hostname)"
    date -u
    uptime || true
    printf '\n== load ==\n'
    cat /proc/loadavg
    printf 'threshold per_core=%s\n' "${CPU_LOAD_PER_CORE}"
    printf '\n== memory (kB) ==\n'
    awk '/^(MemTotal|MemAvailable|MemFree|SwapTotal|SwapFree):/' /proc/meminfo
    printf 'threshold used_percent=%s (MemTotal - MemAvailable)\n' "${MEM_USED_PERCENT}"
    printf '\n== disk ==\n'
    # shellcheck disable=SC2086
    df -hP ${DISK_PATHS} || true
    printf 'threshold used_percent=%s\n' "${DISK_USED_PERCENT}"
    printf '\n== systemd ==\n'
    triage_units
    printf '\n== journal (warning, last 2 hours) ==\n'
    if command -v journalctl >/dev/null 2>&1; then
      journalctl -p warning --since "2 hours ago" --no-pager -n 40 || true
    else
      printf 'journalctl not installed\n'
    fi
    printf '\n== long queries ==\n'
    triage_queries
    printf '\n== backups ==\n'
    if dump=$(latest_dump); then
      printf 'newest_dump=%s\n' "$(basename -- "$dump")"
      printf 'mtime=%s\n' "$(date -u -d "@$(stat -c %Y -- "$dump")" +%Y-%m-%dT%H:%M:%SZ)"
      if verify_manifest "$dump"; then
        printf 'checksum=ok\n'
      else
        printf 'checksum=FAILED\n'
      fi
    else
      printf 'newest_dump=none\n'
    fi
    if [[ -f "$LOG_DIR/restore-tests.log" ]]; then
      printf 'last_restore_test=%s\n' "$(tail -n 1 "$LOG_DIR/restore-tests.log")"
    else
      printf 'last_restore_test=none\n'
    fi
    printf '\n== recent alerts ==\n'
    if [[ -f "$LOG_DIR/alerts.log" ]]; then
      tail -n 30 "$LOG_DIR/alerts.log"
    else
      printf 'none\n'
    fi
    printf '\nrunbooks: %s/docs/runbooks/\n' "$INFRAWATCH_ROOT"
  } | tee "$file"
}
