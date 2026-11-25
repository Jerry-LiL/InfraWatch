# shellcheck shell=bash
# Shared assertions. A failed assert is recorded and finish exits non-zero.
ASSERT_FAIL=0

assert_eq() {
  local got=$1 want=$2 label=$3
  if [[ "$got" == "$want" ]]; then
    printf '  ok  %s\n' "$label"
  else
    printf '  FAIL %s\n    got:  [%s]\n    want: [%s]\n' "$label" "$got" "$want" >&2
    ASSERT_FAIL=1
  fi
}

assert_ok() {
  local label=$1
  shift
  local rc=0
  set +e
  "$@"
  rc=$?
  set -e
  assert_eq "$rc" 0 "$label"
}

assert_fail() {
  local label=$1
  shift
  local rc=0
  set +e
  "$@" >/dev/null
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    printf '  FAIL %s (expected non-zero)\n' "$label" >&2
    ASSERT_FAIL=1
  else
    printf '  ok  %s\n' "$label"
  fi
}

finish() {
  [[ "$ASSERT_FAIL" -eq 0 ]] || exit 1
}
