#!/usr/bin/env bash
# Unit tests. No database. Integration coverage is tests/integration.sh.
set -u
cd "$(dirname "$0")/.." || exit 1
fail=0
for t in tests/*_test.sh; do
  printf '== %s\n' "$t"
  if bash "$t"; then
    printf 'PASS %s\n' "$t"
  else
    printf 'FAIL %s\n' "$t"
    fail=1
  fi
done
exit "$fail"
