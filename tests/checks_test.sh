#!/usr/bin/env bash
set -euo pipefail

ROOT=$(dirname "$(dirname "$(readlink -f "$0")")")
# shellcheck source=assert.sh
source "$(dirname "$(readlink -f "$0")")/assert.sh"
# shellcheck source=../bin/lib/common.sh
source "$ROOT/bin/lib/common.sh"
# shellcheck source=../bin/lib/checks.sh
source "$ROOT/bin/lib/checks.sh"

run_class() {
  local rc=0
  CLASS_OUT=$( "$@" ) || rc=$?
  CLASS_RC=$rc
}

run_class classify_load 1.0 2 1.5
assert_eq "$CLASS_RC" 0 "load under the per-core threshold"
[[ "$CLASS_OUT" == *per_core=0.50* ]]

run_class classify_load 4 2 1.5
assert_eq "$CLASS_RC" 1 "load over the per-core threshold"
[[ "$CLASS_OUT" == *per_core=2.00* ]]

run_class classify_load 3 2 1.5
assert_eq "$CLASS_RC" 0 "load equal to the threshold is not a breach"

run_class classify_memory 100000 20000 90
assert_eq "$CLASS_RC" 0 "memory under the threshold"
[[ "$CLASS_OUT" == *used_percent=80.0* ]]

run_class classify_memory 100000 5000 90
assert_eq "$CLASS_RC" 1 "memory over the threshold"

run_class classify_memory 0 0 90
assert_eq "$CLASS_RC" 2 "missing MemTotal is an error, not an alert"

run_class classify_disk / 85 85
assert_eq "$CLASS_RC" 0 "disk equal to the threshold is ok"

run_class classify_disk /var 86 85
assert_eq "$CLASS_RC" 1 "disk over the threshold alerts"

run_class classify_disk / nope 85
assert_eq "$CLASS_RC" 2 "non-numeric disk percent is an error"

run_class classify_service postgresql active
assert_eq "$CLASS_RC" 0 "active unit is ok"

run_class classify_service postgresql failed
assert_eq "$CLASS_RC" 1 "failed unit alerts"

run_class classify_service postgresql inactive
assert_eq "$CLASS_RC" 1 "inactive unit alerts"

run_class classify_service postgresql "Failed to connect to bus: Host is down"
assert_eq "$CLASS_RC" 2 "unreadable systemd state is an error"

run_class classify_query_count 0 300
assert_eq "$CLASS_RC" 0 "no long queries"

run_class classify_query_count 2 300
assert_eq "$CLASS_RC" 1 "long queries alert"

finish
