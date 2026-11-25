#!/usr/bin/env bash
set -euo pipefail

ROOT=$(dirname "$(dirname "$(readlink -f "$0")")")
# shellcheck source=assert.sh
source "$(dirname "$(readlink -f "$0")")/assert.sh"
# shellcheck source=../bin/lib/backup.sh
source "$ROOT/bin/lib/backup.sh"

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT

export PGDATABASE=app
printf 'abc\n' > "$dir/app_1.dump"
write_manifest "$dir/app_1.dump"
assert_ok "fresh manifest matches" verify_manifest "$dir/app_1.dump"
grep -q '^database=app$' "$dir/app_1.manifest"
grep -q '^format=custom$' "$dir/app_1.manifest"
grep -q '^status=ok$' "$dir/app_1.manifest"

printf 'x' >> "$dir/app_1.dump"
assert_fail "tampered dump fails the checksum" verify_manifest "$dir/app_1.dump"

rm -f "$dir/app_1.manifest"
assert_fail "missing manifest fails closed" verify_manifest "$dir/app_1.dump"

finish
