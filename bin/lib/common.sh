# shellcheck shell=bash
# Shared config, logging, alerting, and locking.

# Repo root, or INFRAWATCH_ROOT when the caller sets it (systemd and cron do).
infrawatch_root() {
  if [[ -n "${INFRAWATCH_ROOT:-}" ]]; then
    readlink -f "$INFRAWATCH_ROOT"
    return
  fi
  local src
  src=$(readlink -f "${BASH_SOURCE[0]}")
  dirname "$(dirname "$(dirname "$src")")"
}

is_uint() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

is_decimal() {
  [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

# 1. $INFRAWATCH_ENV if that variable is set (missing file = load nothing else)
# 2. $ROOT/.env when a checkout has one
# 3. /etc/infrawatch/infrawatch.env on a host install
load_env_file() {
  local root=$1
  local env_file=""
  if [[ -n "${INFRAWATCH_ENV+x}" ]]; then
    env_file=$INFRAWATCH_ENV
  elif [[ -f "$root/.env" ]]; then
    env_file=$root/.env
  elif [[ -f /etc/infrawatch/infrawatch.env ]]; then
    env_file=/etc/infrawatch/infrawatch.env
  fi
  if [[ -n "$env_file" && -f "$env_file" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a
  fi
}

# 1. $INFRAWATCH_CONFIG
# 2. $ROOT/config/infrawatch.conf (a git checkout)
# 3. /etc/infrawatch/infrawatch.conf (after install.sh)
resolve_config() {
  local root=$1
  if [[ -n "${INFRAWATCH_CONFIG:-}" ]]; then
    printf '%s\n' "$INFRAWATCH_CONFIG"
    return
  fi
  if [[ -f "$root/config/infrawatch.conf" ]]; then
    printf '%s\n' "$root/config/infrawatch.conf"
    return
  fi
  printf '%s\n' /etc/infrawatch/infrawatch.conf
}

load_config() {
  local root config
  root=$(infrawatch_root)
  INFRAWATCH_ROOT=$root
  export INFRAWATCH_ROOT

  load_env_file "$root"

  config=$(resolve_config "$root")
  if [[ ! -f "$config" ]]; then
    printf 'infrawatch: config not found: %s\n' "$config" >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  source "$config"

  : "${BACKUP_DIR:?BACKUP_DIR is not set}"
  : "${LOG_DIR:?LOG_DIR is not set}"
  : "${STATE_DIR:?STATE_DIR is not set}"
  mkdir -p "$BACKUP_DIR" "$LOG_DIR" "$STATE_DIR"

  : "${PGHOST:=127.0.0.1}"
  : "${PGPORT:=5432}"
  : "${PGUSER:=infrawatch}"
  : "${PGDATABASE:=app}"
  : "${PGCONNECT_TIMEOUT:=10}"
  # Fixed so health checks can ignore our own sessions.
  PGAPPNAME=infrawatch

  export PGHOST PGPORT PGUSER PGDATABASE PGAPPNAME PGCONNECT_TIMEOUT
  if [[ -n "${PGPASSWORD:-}" ]]; then
    export PGPASSWORD
  fi
  if [[ -n "${PGPASSFILE:-}" ]]; then
    export PGPASSFILE
  fi
}

log_line() {
  local level=$1
  shift
  local msg=$* ts line pri
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  line="${ts} level=${level} ${msg}"
  if [[ -n "${LOG_DIR:-}" ]]; then
    mkdir -p "$LOG_DIR"
    printf '%s\n' "$line" >> "$LOG_DIR/infrawatch.log"
  fi
  # Failures go to stderr (cron mail, a terminal, systemd). Routine info stays
  # in the file. Under systemd, stdout and stderr are already journaled, so
  # skip logger there to avoid a second copy of the same line.
  if [[ "$level" != "info" ]]; then
    printf '%s\n' "$line" >&2
  fi
  case "$level" in
    info) pri=user.info ;;
    warning) pri=user.warning ;;
    error) pri=user.err ;;
    *) pri=user.notice ;;
  esac
  if [[ -z "${JOURNAL_STREAM:-}" ]] && command -v logger >/dev/null 2>&1; then
    logger -t infrawatch -p "$pri" -- "$msg" || true
  fi
}

log_info() { log_line info "$@"; }
log_warn() { log_line warning "$@"; }
log_error() { log_line error "$@"; }

# Operator-facing line: file and journal, and stdout.
say() {
  log_info "$*"
  printf '%s\n' "$*"
}

die() {
  log_error "$*"
  exit 1
}

require_cmd() {
  local missing=0 c
  for c in "$@"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      log_error "required command not found: ${c}"
      missing=1
    fi
  done
  [[ "$missing" -eq 0 ]] || exit 1
}

# severity is ok, warning, or error. The hook is optional and must be executable.
emit_alert() {
  local severity=$1 check=$2 detail=$3
  local ts line
  detail=${detail//$'\n'/ }
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  line="${ts} severity=${severity} check=${check} ${detail}"
  mkdir -p "$LOG_DIR"
  printf '%s\n' "$line" >> "$LOG_DIR/alerts.log"
  case "$severity" in
    ok) log_info "recovered check=${check} ${detail}" ;;
    error) log_error "alert check=${check} ${detail}" ;;
    *) log_warn "alert check=${check} ${detail}" ;;
  esac
  if [[ -z "${ALERT_COMMAND:-}" ]]; then
    return 0
  fi
  if [[ ! -x "$ALERT_COMMAND" ]]; then
    log_error "ALERT_COMMAND is not executable: ${ALERT_COMMAND}"
    return 0
  fi
  ALERT_SEVERITY=$severity ALERT_CHECK=$check ALERT_MESSAGE=$detail \
    "$ALERT_COMMAND" || log_error "ALERT_COMMAND failed: ${ALERT_COMMAND}"
}

# Hold an exclusive lock until this process exits. Contending runs exit 1.
with_lock() {
  local name=$1
  shift
  local lock="${STATE_DIR}/${name}.lock"
  mkdir -p "$STATE_DIR"
  # The fd stays open on purpose: closing it would drop the lock.
  exec {INFRAWATCH_LOCK_FD}>>"$lock"
  if ! flock -n "$INFRAWATCH_LOCK_FD"; then
    die "another ${name} is already running"
  fi
  "$@"
}
