# shellcheck shell=bash
# Host and PostgreSQL health checks. Exit 0 when everything is inside the
# thresholds, 1 when a threshold or a unit state is breached, 2 when a check
# could not be observed (systemd bus down, database unreachable, and so on).

check_key() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'
}

# status is ok, alert, or error. A breach alerts on the transition into that
# state and again after ALERT_REPEAT_SECONDS, not on every timer tick.
record_check() {
  local name=$1 status=$2 detail=$3
  local key state_file prev last now repeat severity
  key=$(check_key "$name")
  state_file="${STATE_DIR}/check_${key}"
  prev=ok
  last=0
  now=$(date +%s)
  mkdir -p "$STATE_DIR" "$LOG_DIR"

  if [[ -f "$state_file" ]]; then
    prev=$(awk 'NR == 1 { print $1 }' "$state_file")
    last=$(awk 'NR == 1 { print $2 }' "$state_file")
    last=${last:-0}
    is_uint "$last" || last=0
  fi

  if [[ "$status" == "ok" ]]; then
    if [[ "$prev" != "ok" ]]; then
      emit_alert ok "$name" "$detail"
    else
      log_info "ok check=${name} ${detail}"
    fi
    printf 'ok 0\n' > "$state_file"
    return 0
  fi

  severity=warning
  [[ "$status" == "error" ]] && severity=error
  repeat=${ALERT_REPEAT_SECONDS:-3600}
  is_uint "$repeat" || repeat=3600

  if [[ "$prev" != "$status" ]] || ((now - last >= repeat)); then
    emit_alert "$severity" "$name" "$detail"
    printf '%s %s\n' "$status" "$now" > "$state_file"
  else
    log_warn "still failing check=${name} ${detail}"
    printf '%s %s\n' "$status" "$last" > "$state_file"
  fi
}

HEALTH_WORST=0

note_status() {
  local rc=$1
  if ((rc > HEALTH_WORST)); then
    HEALTH_WORST=$rc
  fi
}

run_check_result() {
  local name=$1 rc=$2 detail=$3
  local status=ok
  if ((rc != 0 && rc != 1)); then
    rc=2
  fi
  case "$rc" in
    0) status=ok ;;
    1) status=alert ;;
    *) status=error ;;
  esac
  record_check "$name" "$status" "$detail"
  printf '%s %s %s\n' "$name" "$status" "$detail"
  note_status "$rc"
  return 0
}

read_load1() {
  awk 'NR == 1 { print $1 }' /proc/loadavg
}

read_mem_kb() {
  awk '/^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 } END { print t, a }' /proc/meminfo
}

check_cpu() {
  local load cores detail rc=0
  load=$(read_load1)
  cores=$(nproc)
  detail=$(classify_load "$load" "$cores" "$CPU_LOAD_PER_CORE") || rc=$?
  run_check_result "cpu" "$rc" "$detail"
}

check_memory() {
  local total avail detail rc=0
  read -r total avail < <(read_mem_kb)
  detail=$(classify_memory "$total" "$avail" "$MEM_USED_PERCENT") || rc=$?
  run_check_result "memory" "$rc" "$detail"
}

check_disk_path() {
  local path=$1
  local pct err detail rc=0
  err=$(mktemp)
  pct=$(df -P "$path" 2>"$err" | awk 'NR == 2 { gsub(/%/, "", $5); print $5 }' || true)
  if [[ -z "$pct" ]]; then
    detail=$(tr '\n' ' ' < "$err")
    rm -f -- "$err"
    run_check_result "disk ${path}" 2 "path=${path} detail=${detail:-df-failed}"
    return 0
  fi
  rm -f -- "$err"
  detail=$(classify_disk "$path" "$pct" "$DISK_USED_PERCENT") || rc=$?
  run_check_result "disk ${path}" "$rc" "$detail"
}

check_disks() {
  local -a paths=()
  local path
  if [[ -z "${DISK_PATHS// /}" ]]; then
    return 0
  fi
  read -r -a paths <<< "$DISK_PATHS"
  for path in "${paths[@]}"; do
    [[ -n "$path" ]] || continue
    check_disk_path "$path"
  done
}

check_unit() {
  local unit=$1
  local out err detail rc=0
  err=$(mktemp)
  if ! command -v systemctl >/dev/null 2>&1; then
    rm -f -- "$err"
    run_check_result "service ${unit}" 2 "unit=${unit} state=unknown detail=systemctl-not-found"
    return 0
  fi
  # Empty stdout means we never got a state (no systemd bus, for example).
  # A real inactive or failed unit still prints that word.
  out=$(systemctl is-active "$unit" 2>"$err" || true)
  out=${out%%$'\n'*}
  if [[ -z "$out" ]]; then
    detail=$(tr '\n' ' ' < "$err")
    detail=${detail%% }
    rm -f -- "$err"
    run_check_result "service ${unit}" 2 "unit=${unit} state=unknown detail=${detail:-systemctl-failed}"
    return 0
  fi
  rm -f -- "$err"
  detail=$(classify_service "$unit" "$out") || rc=$?
  run_check_result "service ${unit}" "$rc" "$detail"
}

check_units() {
  local -a units=()
  local unit
  if [[ -z "${SYSTEMD_UNITS// /}" ]]; then
    return 0
  fi
  read -r -a units <<< "$SYSTEMD_UNITS"
  for unit in "${units[@]}"; do
    [[ -n "$unit" ]] || continue
    check_unit "$unit"
  done
}

check_queries() {
  local rows err rc=0 count detail
  if [[ "${LONG_QUERY_SECONDS}" == "0" ]]; then
    return 0
  fi
  err=$(mktemp)
  rows=$(query_long_running "$LONG_QUERY_SECONDS" 2>"$err") || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    detail=$(tr '\n' ' ' < "$err")
    rm -f -- "$err"
    run_check_result "long_queries" 2 "detail=${detail:-query-failed}"
    return 0
  fi
  rm -f -- "$err"
  if [[ -z "$rows" ]]; then
    count=0
  else
    count=$(printf '%s\n' "$rows" | wc -l)
    count=${count// /}
  fi
  detail=$(classify_query_count "$count" "$LONG_QUERY_SECONDS") || rc=$?
  if [[ "$count" -gt 0 ]]; then
    detail="${detail} queries=${rows//$'\n'/;}"
  fi
  run_check_result "long_queries" "$rc" "$detail"
}

_run_health() {
  HEALTH_WORST=0
  is_decimal "${CPU_LOAD_PER_CORE:-}" || die "CPU_LOAD_PER_CORE must be a number"
  is_decimal "${MEM_USED_PERCENT:-}" || die "MEM_USED_PERCENT must be a number"
  is_uint "${DISK_USED_PERCENT:-}" || die "DISK_USED_PERCENT must be an integer"
  is_uint "${LONG_QUERY_SECONDS:-}" || die "LONG_QUERY_SECONDS must be an integer"
  is_uint "${ALERT_REPEAT_SECONDS:-}" || die "ALERT_REPEAT_SECONDS must be an integer"

  check_cpu
  check_memory
  check_disks
  check_units
  check_queries

  case "$HEALTH_WORST" in
    0) printf 'health status=ok\n' ;;
    1) printf 'health status=alert\n' ;;
    *) printf 'health status=error\n' ;;
  esac
  return "$HEALTH_WORST"
}

run_health() {
  [[ $# -eq 0 ]] || die "health takes no arguments"
  with_lock health _run_health
}
