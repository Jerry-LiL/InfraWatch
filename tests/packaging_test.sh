#!/usr/bin/env bash
set -euo pipefail

ROOT=$(dirname "$(dirname "$(readlink -f "$0")")")
# shellcheck source=assert.sh
source "$(dirname "$(readlink -f "$0")")/assert.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

DESTDIR=$tmp PREFIX=/opt/infrawatch "$ROOT/bin/install.sh" >"$tmp/install.out"

test -x "$tmp/opt/infrawatch/bin/infrawatch"
test -f "$tmp/opt/infrawatch/bin/lib/backup.sh"
test -f "$tmp/opt/infrawatch/docs/runbooks/restore.md"
test -f "$tmp/opt/infrawatch/docs/runbooks/incident-triage.md"
test -f "$tmp/etc/infrawatch/infrawatch.conf"
test -f "$tmp/etc/cron.d/infrawatch"
test -f "$tmp/etc/logrotate.d/infrawatch"
test -d "$tmp/var/backups/infrawatch"
test -d "$tmp/var/log/infrawatch"
test -d "$tmp/var/lib/infrawatch"
printf '  ok  staged install layout\n'

grep -q 'BACKUP_DIR:-/var/backups/infrawatch' "$tmp/etc/infrawatch/infrawatch.conf"
grep -q 'SYSTEMD_UNITS:-postgresql' "$tmp/etc/infrawatch/infrawatch.conf"
grep -q 'infrawatch backup' "$tmp/etc/cron.d/infrawatch"
grep -q 'infrawatch restore-test' "$tmp/etc/cron.d/infrawatch"
grep -q 'infrawatch health' "$tmp/etc/cron.d/infrawatch"
grep -F -q 'OnCalendar=*-*-* 02:15:00' "$tmp/etc/systemd/system/infrawatch-backup.timer"
grep -F -q 'OnCalendar=*-*-* 03:30:00' "$tmp/etc/systemd/system/infrawatch-restore-test.timer"
grep -F -q 'OnCalendar=*:0/5' "$tmp/etc/systemd/system/infrawatch-healthcheck.timer"
grep -q 'ExecStart=/opt/infrawatch/bin/infrawatch backup' "$tmp/etc/systemd/system/infrawatch-backup.service"
grep -q 'ExecStart=/opt/infrawatch/bin/infrawatch restore-test' "$tmp/etc/systemd/system/infrawatch-restore-test.service"
grep -q 'ExecStart=/opt/infrawatch/bin/infrawatch health' "$tmp/etc/systemd/system/infrawatch-healthcheck.service"
grep -q 'SyslogIdentifier=infrawatch' "$tmp/etc/systemd/system/infrawatch-healthcheck.service"
grep -q '/var/log/infrawatch/\*\.log' "$tmp/etc/logrotate.d/infrawatch"
printf '  ok  cron, timers, and logrotate contents\n'

# Second install must not clobber a config the operator already edited.
printf '\n# local edit\n' >> "$tmp/etc/infrawatch/infrawatch.conf"
DESTDIR=$tmp PREFIX=/opt/infrawatch "$ROOT/bin/install.sh" >/dev/null
grep -q 'local edit' "$tmp/etc/infrawatch/infrawatch.conf"
printf '  ok  existing config is kept\n'

# The staged program can load the staged config when paths are overridden.
cat > "$tmp/env" <<EOF
BACKUP_DIR=$tmp/backups
LOG_DIR=$tmp/log
STATE_DIR=$tmp/state
RETENTION_DAYS=14
RETENTION_MIN_KEEP=1
SYSTEMD_UNITS=
LONG_QUERY_SECONDS=0
EOF
mkdir -p "$tmp/backups" "$tmp/log" "$tmp/state"
set +e
INFRAWATCH_CONFIG=$tmp/etc/infrawatch/infrawatch.conf \
  INFRAWATCH_ENV=$tmp/env \
  INFRAWATCH_ROOT=$tmp/opt/infrawatch \
  "$tmp/opt/infrawatch/bin/infrawatch" prune >"$tmp/out" 2>"$tmp/err"
rc=$?
set -e
assert_eq "$rc" 0 "installed script prunes using the staged config"

if command -v systemd-analyze >/dev/null 2>&1; then
  for spec in '*-*-* 02:15:00' '*-*-* 03:30:00' '*:0/5'; do
    systemd-analyze calendar "$spec" >/dev/null
  done
  printf '  ok  systemd-analyze calendar\n'
fi

if command -v logrotate >/dev/null 2>&1; then
  # logrotate ignores a snippet that is not owned by root, and the su directive
  # has to be allowed to switch user, so the dry run is done as root.
  rot=$(mktemp)
  cp "$ROOT/config/logrotate/infrawatch" "$rot"
  if [[ "$(id -u)" -eq 0 ]]; then
    logrotate -d "$rot" >"$tmp/logrotate.out" 2>&1 || {
      cat "$tmp/logrotate.out" >&2
      exit 1
    }
  elif sudo -n true 2>/dev/null; then
    sudo chown root:root "$rot"
    # Redirect is the caller's on purpose so the log stays readable here.
    # shellcheck disable=SC2024
    sudo logrotate -d "$rot" >"$tmp/logrotate.out" 2>&1 || {
      cat "$tmp/logrotate.out" >&2
      exit 1
    }
  else
    printf '  skip logrotate -d (needs root)\n'
    rm -f "$rot"
    rot=""
  fi
  if [[ -n "$rot" ]]; then
    if [[ "$(id -u)" -eq 0 ]]; then
      rm -f "$rot"
    else
      sudo rm -f "$rot"
    fi
    if grep -q 'error:' "$tmp/logrotate.out"; then
      cat "$tmp/logrotate.out" >&2
      exit 1
    fi
    printf '  ok  logrotate -d\n'
  fi
fi

finish
