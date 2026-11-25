#!/usr/bin/env bash
set -euo pipefail

ROOT=$(dirname "$(dirname "$(readlink -f "$0")")")
# shellcheck source=assert.sh
source "$(dirname "$(readlink -f "$0")")/assert.sh"
# shellcheck source=../bin/lib/prune.sh
source "$ROOT/bin/lib/prune.sh"

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT

make_dump() {
  local name=$1 when=$2
  printf 'dump %s\n' "$name" > "$dir/${name}.dump"
  printf 'sha256=placeholder\n' > "$dir/${name}.manifest"
  touch -d "$when" "$dir/${name}.dump"
}

names() {
  local f
  shopt -s nullglob
  for f in "$dir"/*.dump; do
    basename -- "$f"
  done
  shopt -u nullglob
}

make_dump a '1 day ago'
make_dump b '2 days ago'
make_dump c '20 days ago'
make_dump d '30 days ago'
make_dump e '40 days ago'
printf 'keep me\n' > "$dir/notes.txt"

# Newest three are kept even though c is past the age limit. d and e go.
removed=$(prune_backups "$dir" 14 3 | sort)
assert_eq "$removed" "$(printf 'd.dump\ne.dump')" "prunes past the age limit above min keep"
remain=$(names | sort)
assert_eq "$remain" "$(printf 'a.dump\nb.dump\nc.dump')" "keeps the newest min_keep dumps"
[[ -f "$dir/c.manifest" ]]
[[ ! -f "$dir/d.manifest" ]]
[[ -f "$dir/notes.txt" ]]
printf '  ok  manifest sidecar removed with the dump\n'

rm -rf "$dir"
mkdir -p "$dir"
make_dump a '1 day ago'
make_dump c '20 days ago'
removed=$(prune_backups "$dir" 14 0 | sort)
assert_eq "$removed" "c.dump" "min_keep 0 still keeps dumps inside the window"

rm -rf "$dir"
mkdir -p "$dir"
make_dump a '30 days ago'
make_dump b '40 days ago'
make_dump c '50 days ago'
removed=$(prune_backups "$dir" 14 5 || true)
assert_eq "$removed" "" "min_keep larger than the set deletes nothing"

finish
