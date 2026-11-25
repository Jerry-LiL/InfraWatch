#!/usr/bin/env bash
set -euo pipefail

ROOT=$(dirname "$(dirname "$(readlink -f "$0")")")
# shellcheck source=assert.sh
source "$(dirname "$(readlink -f "$0")")/assert.sh"
# shellcheck source=../bin/lib/common.sh
source "$ROOT/bin/lib/common.sh"
# shellcheck source=../bin/lib/health.sh
source "$ROOT/bin/lib/health.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
LOG_DIR=$tmp/log
STATE_DIR=$tmp/state
export ALERT_REPEAT_SECONDS=3600
mkdir -p "$LOG_DIR" "$STATE_DIR"

hook=$tmp/hook.sh
hook_log=$tmp/hook.log
cat > "$hook" <<'EOF'
#!/usr/bin/env bash
printf '%s %s %s\n' "$ALERT_SEVERITY" "$ALERT_CHECK" "$ALERT_MESSAGE" >> "$HOOK_LOG"
EOF
chmod 755 "$hook"
export ALERT_COMMAND=$hook
HOOK_LOG=$hook_log
export HOOK_LOG

record_check "disk /" alert "path=/ used_percent=96 threshold=85"
record_check "disk /" alert "path=/ used_percent=96 threshold=85"
assert_eq "$(grep -c 'severity=warning' "$LOG_DIR/alerts.log")" 1 "repeat inside the window does not page again"

printf 'alert 0\n' > "$STATE_DIR/check_disk__"
record_check "disk /" alert "path=/ used_percent=97 threshold=85"
assert_eq "$(grep -c 'severity=warning' "$LOG_DIR/alerts.log")" 2 "repeat after the window pages again"

record_check "disk /" ok "path=/ used_percent=10 threshold=85"
grep -q 'severity=ok check=disk /' "$LOG_DIR/alerts.log"
printf '  ok  recovery is recorded\n'

assert_eq "$(wc -l < "$hook_log" | tr -d ' ')" 3 "alert command ran for alerts and recovery"
grep -q 'warning disk /' "$hook_log"
grep -q 'ok disk /' "$hook_log"

finish
